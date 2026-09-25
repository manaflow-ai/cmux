#!/usr/bin/env python3
"""Tests for scripts/ci/owned_build_state.py and its compile-admission wiring (no network)."""

from __future__ import annotations

import hashlib
import io
import json
import os
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
        self.source = base / "canonical" / "src"
        self.packages = self.source / ".ci-source-packages"
        self.workspace.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def keep(self, fingerprint="fp"):
        """A previous job's saved state."""
        (self.derived / "Build").mkdir(parents=True)
        (self.derived / "Build" / "obj.o").write_bytes(b"x" * 10)
        (self.derived / "Logs").mkdir()
        self.packages.mkdir(parents=True)
        (self.packages / "checkouts").mkdir()
        kept = run(state.keep, self.store, self.derived, fingerprint)
        saved = run(state.save, self.store, self.packages, self.workspace)
        return {**kept, **saved}


class Check(Fixture):
    def test_cold_store(self):
        result = run(state.check, self.store, "fp", self.workspace)
        self.assertEqual((result["warm"], result["packages"]), ("false", "false"))

    def test_warm_store_hands_everything_back(self):
        saved = self.keep()
        self.assertEqual(saved, {"kept": "true", "packages": "true"})
        self.assertFalse((self.store / "derived-data" / "Logs").exists())
        # keep clones: the job's own DerivedData stays for the steps after it.
        self.assertTrue((self.derived / "Build" / "obj.o").is_file())
        result = run(state.check, self.store, "fp", self.workspace)
        self.assertEqual((result["warm"], result["packages"]), ("true", "true"))
        self.assertTrue((self.workspace / ".ci-source-packages" / "checkouts").is_dir())
        # The DerivedData stays in the store until adopt, after the resolve.
        self.assertTrue((self.store / "derived-data" / "Build" / "obj.o").is_file())

    def test_another_xcode_or_layout_is_cold_but_keeps_the_derived_data(self):
        # A rerun of an older merge commit must not wipe what current jobs
        # use; the next successful keep replaces it.
        self.keep(fingerprint="old")
        result = run(state.check, self.store, "new", self.workspace)
        self.assertEqual((result["warm"], result["packages"]), ("false", "true"))
        self.assertTrue((self.store / "derived-data" / "Build" / "obj.o").is_file())
        self.assertEqual(run(state.check, self.store, "old", self.workspace)["warm"], "true")

    def test_an_oversized_derived_data_is_dropped(self):
        self.keep()
        with unittest.mock.patch.object(state, "MAX_DERIVED_BYTES", 5):
            result = run(state.check, self.store, "fp", self.workspace)
        self.assertEqual(result["warm"], "false")
        self.assertIn("grew", result["reason"])
        self.assertFalse((self.store / "derived-data").exists())

    def test_an_empty_fingerprint_is_never_warm(self):
        self.keep()
        self.assertEqual(run(state.check, self.store, "", self.workspace)["warm"], "false")


class AdoptAndSave(Fixture):
    def test_adopt_swaps_the_kept_derived_data_in(self):
        self.keep()
        # The resolve step deletes the DerivedData and recreates it.
        state.remove(self.derived)
        self.derived.mkdir(parents=True)
        (self.derived / "fresh").write_text("resolve")
        result = run(state.adopt, self.store, self.derived, self.source)
        self.assertEqual(result["hit"], "true")
        # Kept before inputs were recorded: adopted, but nothing to replay.
        self.assertEqual(result["replayed"], "false")
        self.assertTrue((self.derived / "Build" / "obj.o").is_file())
        self.assertFalse((self.derived / "fresh").exists())
        # A clone: the store keeps it until a successful keep replaces it.
        self.assertTrue((self.store / "derived-data" / "Build" / "obj.o").is_file())

    def test_adopt_without_a_kept_derived_data_is_a_miss(self):
        self.assertEqual(run(state.adopt, self.store, self.derived, self.source)["hit"], "false")

    def test_a_failed_or_cancelled_compile_leaves_the_mac_warm(self):
        # No keep after a failed compile, and a cancelled job may not even
        # reach save: the store still holds what the job started from.
        self.keep()
        state.remove(self.packages)
        run(state.check, self.store, "fp", self.workspace)
        run(state.adopt, self.store, self.derived, self.source)
        (self.derived / "Build" / "half.o").write_text("interrupted")
        state.remove(self.workspace / ".ci-source-packages")
        result = run(state.check, self.store, "fp", self.workspace)
        self.assertEqual((result["warm"], result["packages"]), ("true", "true"))
        self.assertFalse((self.store / "derived-data" / "Build" / "half.o").exists())
        self.assertTrue((self.store / "source-packages" / "checkouts").is_dir())

    def test_packages_a_job_never_resolved_are_still_kept(self):
        self.keep()
        state.remove(self.packages)
        run(state.check, self.store, "fp", self.workspace)  # cloned into the workspace
        (self.workspace / ".ci-source-packages" / "checkouts" / "new").write_text("fetched")
        result = run(state.save, self.store, self.packages, self.workspace)
        self.assertEqual(result["packages"], "true")
        self.assertTrue((self.store / "source-packages" / "checkouts" / "new").is_file())
        self.assertEqual([path.name for path in self.store.iterdir() if path.name.startswith(".")], [])

    def test_a_job_without_packages_leaves_the_kept_ones(self):
        self.keep()
        state.remove(self.packages)
        self.assertEqual(run(state.save, self.store, self.packages, self.workspace)["packages"], "false")
        self.assertTrue((self.store / "source-packages" / "checkouts").is_dir())

    def test_every_slot_shares_the_macs_packages(self):
        self.keep()
        shared, slot = self.store, self.store / "cmux-ci-2"
        state.remove(self.packages)
        result = run(state.check, slot, "fp", self.workspace, shared)
        self.assertEqual((result["warm"], result["packages"]), ("false", "true"))
        self.assertFalse((slot / "source-packages").exists())
        (self.workspace / ".ci-source-packages" / "slot2").write_text("x")
        self.assertEqual(run(state.save, slot, self.packages, self.workspace, shared)["packages"], "true")
        self.assertTrue((shared / "source-packages" / "slot2").is_file())
        self.assertFalse((slot / "source-packages").exists())

    def test_a_save_that_loses_a_race_leaves_nothing_behind(self):
        self.keep()
        (self.store / ".source-packages.incoming-1").mkdir()  # a cancelled save
        (self.store / "cmux-ci-2" / "source-packages").mkdir(parents=True)  # pre-shared slot copy
        self.packages.mkdir(parents=True)
        real = Path.rename
        def racing(path, target):
            if Path(target).name == "source-packages":
                raise OSError(66, "Directory not empty")
            return real(path, target)
        with unittest.mock.patch.object(Path, "rename", racing):
            result = run(state.save, self.store / "cmux-ci-2", self.packages, self.workspace, self.store)
        self.assertEqual(result["packages"], "false")
        self.assertEqual([path.name for path in self.store.iterdir() if path.name.startswith(".")], [])
        self.assertFalse((self.store / "cmux-ci-2" / "source-packages").exists())

    def test_a_package_clone_that_loses_a_race_is_a_miss(self):
        self.keep()
        with unittest.mock.patch.object(state, "clone", side_effect=OSError("gone")):
            result = run(state.check, self.store, "fp", self.workspace)
        self.assertEqual((result["warm"], result["packages"]), ("true", "false"))
        self.assertIn("gone", result["packages_error"])
        self.assertFalse((self.workspace / ".ci-source-packages").exists())

    def test_keep_replaces_the_old_derived_data_whole(self):
        self.keep()
        (self.derived / "Build" / "new.o").write_text("new")
        (self.derived / "Build" / "obj.o").unlink()
        self.assertEqual(run(state.keep, self.store, self.derived, "fp2")["kept"], "true")
        kept = self.store / "derived-data"
        self.assertEqual(sorted(path.name for path in (kept / "Build").iterdir()), ["new.o"])
        self.assertFalse((kept / "derived-data-compile-admission").exists())
        self.assertEqual(json.loads((self.store / "stamp.json").read_text())["fingerprint"], "fp2-owned-rec1")
        self.assertEqual([path.name for path in self.store.iterdir() if path.name.startswith(".")], [])

    def test_clear_refuses_to_leave_anything_behind(self):
        target = self.store / "x"
        target.mkdir(parents=True)
        with unittest.mock.patch.object(state, "remove"), \
             unittest.mock.patch.object(Path, "rename"):
            with self.assertRaises(RuntimeError):
                state.clear(target)

    def test_keep_needs_a_fingerprint(self):
        self.derived.mkdir(parents=True)
        self.assertEqual(run(state.keep, self.store, self.derived, "")["kept"], "false")

    def test_main_rejects_wrong_arguments(self):
        with unittest.mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(state.main(["x", "check", "only"]), 2)


class Replay(Fixture):
    """A warm job must see the times the kept build saw, not the copy's (job 107904138254)."""

    OLD = 1_700_000_000_000_000_000

    def write_source(self, files):
        for relative, text in files.items():
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def test_the_next_job_replays_the_recorded_times_onto_unchanged_inputs(self):
        self.write_source({"Sources/a.swift": "a", "Sources/b.swift": "b"})
        for path in (self.source / "Sources").iterdir():
            os.utime(path, ns=(self.OLD, self.OLD))
        self.derived.mkdir(parents=True)
        self.assertEqual(run(state.record, self.source, self.derived)["recorded"], "true")
        self.assertEqual(run(state.keep, self.store, self.derived, "fp")["kept"], "true")

        # The next job: a fresh copy stamped now, with one file changed.
        state.remove(self.source)
        state.remove(self.derived)
        self.write_source({"Sources/a.swift": "a", "Sources/b.swift": "b changed"})
        self.derived.mkdir(parents=True)
        result = run(state.adopt, self.store, self.derived, self.source)
        self.assertEqual((result["hit"], result["replayed"]), ("true", "true"))
        self.assertEqual((result["unchanged_inputs"], result["changed_inputs"]), ("1", "1"))
        self.assertEqual((self.source / "Sources/a.swift").stat().st_mtime_ns, self.OLD)
        self.assertGreater((self.source / "Sources/b.swift").stat().st_mtime_ns, self.OLD)

    def seed_record_for(self, text):
        """A seed's record: content `text` at the seed's old time."""
        digest = hashlib.sha256(text.encode()).hexdigest()
        return json.dumps({"Sources/a.swift": [digest, self.OLD]})

    def test_a_seed_record_in_a_kept_derived_data_is_never_replayed(self):
        # The #14250 case: the kept build compiled content B, the seed it was
        # adopted from recorded content A at an old time, and the tree has A
        # again. Aging A to the seed's time would hide it from swift-driver.
        self.derived.mkdir(parents=True)
        (self.derived / state.seed.MANIFEST).write_text(self.seed_record_for("A"))
        self.assertEqual(run(state.keep, self.store, self.derived, "fp")["kept"], "true")
        self.assertFalse((self.store / "derived-data" / state.seed.MANIFEST).exists())
        # Even one that reaches the store some other way is not read.
        (self.store / "derived-data" / state.seed.MANIFEST).write_text(self.seed_record_for("A"))
        self.write_source({"Sources/a.swift": "A"})
        self.derived = self.derived.with_name("next")
        result = run(state.adopt, self.store, self.derived, self.source)
        self.assertEqual((result["hit"], result["replayed"]), ("true", "false"))
        self.assertGreater((self.source / "Sources/a.swift").stat().st_mtime_ns, self.OLD)

    def test_derived_data_kept_before_the_owned_record_is_never_warm(self):
        # Stamped by the previous owned_build_state.py: bare fingerprint, and
        # possibly the seed's record inside. It stays for that script's jobs
        # until a current job's keep replaces it.
        (self.store / "derived-data").mkdir(parents=True)
        (self.store / "derived-data" / state.seed.MANIFEST).write_text(self.seed_record_for("A"))
        (self.store / "stamp.json").write_text(json.dumps({"fingerprint": "fp"}))
        result = run(state.check, self.store, "fp", self.workspace)
        self.assertEqual(result["warm"], "false")
        self.derived.mkdir(parents=True)
        self.assertEqual(run(state.keep, self.store, self.derived, "fp")["kept"], "true")
        self.assertFalse((self.store / "derived-data" / state.seed.MANIFEST).exists())
        self.assertEqual(run(state.check, self.store, "fp", self.workspace)["warm"], "true")

    def test_a_failed_record_leaves_no_stale_record_behind(self):
        self.derived.mkdir(parents=True)
        (self.derived / state.RECORD).write_text(self.seed_record_for("A"))
        with unittest.mock.patch.object(state.seed.warm, "record", side_effect=OSError("disk")):
            with self.assertRaises(OSError):
                run(state.record, self.source, self.derived)
        self.assertFalse((self.derived / state.RECORD).exists())
        run(state.keep, self.store, self.derived, "fp")
        self.derived = self.derived.with_name("next")
        self.assertEqual(run(state.adopt, self.store, self.derived, self.source)["replayed"], "false")

    def test_record_replaces_the_old_record_and_leaves_the_seeds_alone(self):
        self.write_source({"a.swift": "a"})
        self.derived.mkdir(parents=True)
        (self.derived / state.RECORD).write_text(json.dumps({"stale": ["x", 1]}))
        (self.derived / state.seed.MANIFEST).write_text("seed")
        run(state.record, self.source, self.derived)
        recorded = json.loads((self.derived / state.RECORD).read_text())
        self.assertNotIn("stale", recorded)
        self.assertIn("a.swift", recorded)
        self.assertNotEqual(state.RECORD, state.seed.MANIFEST)


class Prefer(Fixture):
    """A warm Mac adopts a seed instead when the seed rebuilds less."""

    def setUp(self):
        super().setUp()
        self.cache = Path(self.tmp.name) / "seeds"
        self.env = unittest.mock.patch.dict(os.environ, {"CMUX_SEED_LOCAL_CACHE": str(self.cache)})
        self.env.start()
        self.addCleanup(self.env.stop)
        (self.workspace / "Sources").mkdir()
        for index in range(6):
            (self.workspace / "Sources" / f"F{index}.swift").write_text(f"let f{index} = 0\n")

    def recorded(self, changed):
        """A record of the workspace with CHANGED files edited since."""
        record = state.seed.warm.record(self.workspace)
        for index in range(changed):
            record[f"Sources/F{index}.swift"] = ["stale", 1]
        return record

    def kept(self, changed):
        (self.store / "derived-data").mkdir(parents=True)
        (self.store / "derived-data" / state.RECORD).write_text(json.dumps(self.recorded(changed)))

    def kept_seed(self, key, changed):
        (self.cache / key).mkdir(parents=True)
        (self.cache / key / state.seed.MANIFEST).write_text(json.dumps(self.recorded(changed)))

    def prefer(self, located=("p-j14-base", 0), max_distance=None):
        with unittest.mock.patch.object(state.seed, "locate", return_value=located):
            return state.prefer(self.store, self.workspace, "p-", "base", max_distance)

    def test_changed_inputs_counts_edits_additions_and_deletions(self):
        now = {"a": ["1", 0], "b": ["2", 0], "dir/": ["x", 0], ".ci-source-packages/p": ["9", 0]}
        then = {"a": ["1", 5], "b": ["3", 0], "c": ["4", 0], "dir/": ["y", 0]}
        self.assertEqual(state.changed_inputs(now, then), 2)

    def test_a_kept_seed_with_fewer_changed_inputs_wins(self):
        self.kept(changed=5)
        self.kept_seed("p-j14-base", changed=1)
        result = self.prefer()
        self.assertEqual((result["prefer"], result["kept_changed"], result["seed_changed"], result["local"]),
                         ("true", "5", "1", "true"))

    def test_the_kept_derived_data_wins_a_tie_or_better(self):
        self.kept(changed=1)
        self.kept_seed("p-j14-base", changed=1)
        self.assertEqual(self.prefer()["prefer"], "false")

    def test_a_seed_to_download_wins_only_within_max_distance(self):
        self.kept(changed=3)
        self.assertEqual(self.prefer(("p-j14-base", 2))["prefer"], "false")
        self.assertEqual(self.prefer(("p-j14-base", 2), max_distance=2)["prefer"], "true")
        self.assertEqual(self.prefer(("p-j14-base", 3), max_distance=2)["prefer"], "false")

    def test_an_unchanged_kept_derived_data_is_never_replaced_by_a_download(self):
        self.kept(changed=0)
        self.assertEqual(self.prefer(("p-j14-base", 0), max_distance=5)["prefer"], "false")

    def test_no_seed_or_no_record(self):
        self.kept(changed=3)
        self.assertEqual(self.prefer(("p-j14-base", None))["prefer"], "false")
        (self.store / "derived-data" / state.RECORD).unlink()
        self.assertEqual(self.prefer(("p-j14-base", 9))["prefer"], "true")

    def test_any_error_keeps_the_warm_path(self):
        output = Path(self.tmp.name) / "output"
        with unittest.mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}), \
             unittest.mock.patch.object(state.seed, "locate", side_effect=RuntimeError("boom")), \
             unittest.mock.patch("sys.stdout", io.StringIO()):
            self.assertEqual(state.main(["x", "prefer", str(self.store), str(self.workspace), "p-", "base", "local"]), 0)
        self.assertIn("prefer=false", output.read_text())


class WorkflowCommandLines(unittest.TestCase):
    """Run every owned_build_state.py line of the workflow as written (run 36064525977 exited 2)."""

    def test_each_workflow_call_is_one_the_script_accepts(self):
        import re
        import subprocess

        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-macos.yml").read_text())
        steps = workflow["jobs"]["macos-compile-admission"]["steps"]
        calls = [step for step in steps if "owned_build_state.py" in str(step.get("run", ""))]
        self.assertEqual(len(calls), 6)
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / "derived").mkdir()
            env = {"PATH": "/usr/bin:/bin", "CMUX_OWNED_STATE_ROOT": str(base / "store"),
                   "CMUX_COMPILE_ADMISSION_DERIVED_DATA": str(base / "derived"),
                   "CMUX_CI_CANONICAL_SRC": str(base / "src"), "FINGERPRINT": "fp",
                   "HOME": str(base)}
            for step in calls:
                script = step["run"]
                # The fingerprint comes from Xcode; stand in for it.
                script = re.sub(r'fingerprint="\$\(scripts/ci/compile-app-host-test-product\.sh[^\n]*\n',
                                'fingerprint=fp\n', script)
                script = script.replace('>> "$GITHUB_OUTPUT"', ">/dev/null")
                script = script.replace("python3 scripts/ci/owned_build_state.py",
                                        f"{sys.executable} {ROOT / 'scripts/ci/owned_build_state.py'}")
                result = subprocess.run(["bash", "-c", script], cwd=base, env=env, capture_output=True, text=True)
                # adopt runs `defaults` on macOS only after a hit; a miss here is fine.
                self.assertEqual(result.returncode, 0, f"{step['name']}: {result.stderr[-400:]}")
                self.assertNotIn("owned_build_state.py check STORE", result.stderr, step["name"])


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
        self.assertIn("github.event_name == 'pull_request'", self.by_id["owned-state"]["if"])
        # Every other state step follows owned-state.
        self.assertIn("steps.owned-state.outcome != 'skipped'", self.step("Keep this owned Mac's build state")["if"])
        self.assertIn("steps.owned-state.outputs.fingerprint != ''", self.step("Keep this owned Mac's DerivedData")["if"])
        self.assertIn("steps.owned-state.outputs.warm == 'true'", self.by_id["owned-adopt"]["if"])
        self.assertIn("steps.owned-state.outputs.fingerprint != ''", self.step("Record this owned Mac's build inputs")["if"])
        for step in (self.by_id["owned-state"], self.by_id["owned-adopt"], self.step("Record this owned Mac's build inputs"),
                     self.step("Keep this owned Mac's DerivedData"), self.step("Keep this owned Mac's build state")):
            self.assertIs(step.get("continue-on-error"), True, step["name"])
            self.assertNotIn("uses", step, step["name"])
        self.assertEqual(self.job["env"]["CMUX_OWNED_STATE_ROOT"], "/Users/Shared/cmux-build-fleet/ci")

    def test_a_warm_mac_skips_the_seed_and_the_package_cache(self):
        self.assertIn("steps.owned-state.outputs.warm != 'true'", self.by_id["seed-derived-data"]["if"])
        self.assertIn("steps.owned-state.outputs.warm != 'true'", self.step("Start the DerivedData seed download")["if"])
        self.assertIn("steps.owned-state.outputs.packages != 'true'", self.by_id["swift-package-cache"]["if"])

    def test_a_near_seed_replaces_the_kept_state_only_when_asked_and_it_hits(self):
        prefer = self.by_id["prefer-seed"]
        self.assertIn("steps.owned-state.outputs.warm == 'true'", prefer["if"])
        self.assertIn("vars.CI_OWNED_PREFER_SEED != ''", prefer["if"])
        self.assertIs(prefer.get("continue-on-error"), True)
        for step in (self.by_id["seed-derived-data"], self.step("Start the DerivedData seed download")):
            self.assertIn("steps.prefer-seed.outputs.prefer == 'true'", step["if"])
            self.assertIn("CMUX_SEED_LOCAL_CACHE", step["env"])
        # A preferred seed that misses still leaves the Mac warm.
        self.assertIn("steps.seed-derived-data.outputs.hit != 'true'", self.by_id["owned-adopt"]["if"])
        index = self.names.index
        self.assertLess(index("Reuse this owned Mac's build state"), index("Prefer a near seed over this owned Mac's DerivedData"))
        self.assertLess(index("Prefer a near seed over this owned Mac's DerivedData"), index("Start the DerivedData seed download"))
        self.assertLess(index("Adopt the nightly DerivedData seed"), index("Adopt this owned Mac's DerivedData"))

    def test_the_product_key_does_not_see_owned_state(self):
        # product_input_identity fingerprints every step it does not list as
        # non-product, comment lines after a step included. Owned state must
        # decide only how much is rebuilt, never the product key of any pool.
        import product_input_identity as identity

        text = (ROOT / ".github/workflows/ci-macos.yml").read_text()
        for name in ("Reuse this owned Mac's build state", "Prefer a near seed over this owned Mac's DerivedData",
                     "Adopt this owned Mac's DerivedData",
                     "Record this owned Mac's build inputs", "Keep this owned Mac's DerivedData",
                     "Keep this owned Mac's build state"):
            self.assertIn(name, identity.NON_PRODUCT_RECIPE_STEPS)
        steps = identity.recipe_projection(text)["steps"]
        for name, block in steps.items():
            self.assertNotIn("owned", block.lower(), name)
        self.assertNotIn("CMUX_OWNED_STATE_ROOT", identity.recipe_projection(text)["job_controls"]["env"])

    def test_order(self):
        index = self.names.index
        self.assertLess(index("Capture Ghostty revision"), index("Reuse this owned Mac's build state"))
        self.assertLess(index("Reuse this owned Mac's build state"), index("Cache GhosttyKit.xcframework"))
        self.assertLess(index("Resolve Swift packages"), index("Adopt this owned Mac's DerivedData"))
        self.assertLess(index("Adopt the nightly DerivedData seed"), index("Adopt this owned Mac's DerivedData"))
        self.assertLess(index("Adopt this owned Mac's DerivedData"), index("Record this owned Mac's build inputs"))
        self.assertLess(index("Record this owned Mac's build inputs"), index("Compile app-host test product"))
        # adopt replays onto the canonical tree the compile builds.
        self.assertIn('"$CMUX_CI_CANONICAL_SRC"', self.by_id["owned-adopt"]["run"])
        self.assertLess(index("Forget the adopted-build inode override"), index("Keep this owned Mac's DerivedData"))
        self.assertLess(index("Seed node-local compiled product cache"), index("Keep this owned Mac's build state"))
        self.assertLess(index("Keep this owned Mac's build state"), index("Prepare isolated DerivedData"))
        self.assertIn("steps.owned-adopt.outcome", self.step("Forget the adopted-build inode override")["if"])

    def slot(self, root, runner="glaeda-std-xcode-26.6"):
        """Run the build-slot step; (exit code, GITHUB_ENV, GITHUB_OUTPUT)."""
        import os
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            env_file, out_file = Path(tmp, "env"), Path(tmp, "out")
            env = {"PATH": os.environ["PATH"], "GITHUB_ENV": str(env_file), "GITHUB_OUTPUT": str(out_file),
                   "CMUX_PRODUCT_RUNNER": runner, "CMUX_OWNED_STATE_ROOT": "/Users/Shared/cmux-build-fleet/ci"}
            if root is not None:
                env["CMUX_CI_CANONICAL_ROOT"] = root
            result = subprocess.run(["bash", "-c", self.by_id["build-slot"]["run"]], env=env,
                                    capture_output=True, text=True)
            read = lambda path: path.read_text() if path.exists() else ""
            return result.returncode, read(env_file), read(out_file)

    def test_a_second_compile_slot_keeps_its_own_root_and_state(self):
        # The first slot, and every Blacksmith job, keeps the default root and store.
        for runner in ("glaeda-std-xcode-26.6", "blacksmith-6vcpu-macos-26"):
            self.assertEqual(self.slot(None, runner), (0, "", "root=/private/tmp/cmux-ci\n"))
        code, env, out = self.slot("/private/tmp/cmux-ci-2")
        self.assertEqual(code, 0)
        self.assertEqual(env, "CMUX_OWNED_PACKAGE_STORE=/Users/Shared/cmux-build-fleet/ci\n"
                              "CMUX_OWNED_STATE_ROOT=/Users/Shared/cmux-build-fleet/ci/cmux-ci-2\n")
        self.assertEqual(out, "root=/private/tmp/cmux-ci-2\n")
        # Only an owned Mac may move the root, and only to a slot root.
        self.assertNotEqual(self.slot("/private/tmp/cmux-ci-2", "blacksmith-6vcpu-macos-26")[0], 0)
        for bad in ("/tmp/elsewhere", "/private/tmp/cmux-ci-x", "/private/tmp/cmux-ci/../x"):
            self.assertNotEqual(self.slot(bad)[0], 0, bad)
        # It runs before anything reads the root, and is not part of the product key.
        index = self.names.index
        self.assertLess(index("Choose this job's canonical build root"), index("Prepare isolated admission DerivedData"))
        import product_input_identity as identity
        self.assertIn("Choose this job's canonical build root", identity.NON_PRODUCT_RECIPE_STEPS)

    def test_consumers_alias_their_checkout_at_the_producers_root(self):
        # Stamp as ci-macos.yml and test-e2e.yml do: once from <root>/src, then
        # again from the job workspace when packaging. `derived` names the
        # root at both; `checkout` ends up as the workspace. The restore
        # snippet then exports the producer's root, whatever this runner's.
        import os
        import subprocess
        import app_host_test_products as products
        script = (ROOT / "scripts/ci/restore-app-host-test-product.sh").read_text()
        start = script.index('producer_derived="$(')
        end = script.index("esac", start) + len("esac")
        self.assertLess(end, script.index('scripts/ci/canonical-build-root.sh --runtime-source "$PWD"'))
        for slot, expected in (("cmux-ci-2", "cmux-ci-2"), ("cmux-ci", "cmux-ci"), ("elsewhere", None)):
            with tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp).resolve()
                derived = base / "private/tmp" / slot / "derived-data-compile-admission"
                (derived / "Build" / "Products").mkdir(parents=True)
                # No test manifests here: stamp only validates them.
                with unittest.mock.patch.object(products, "manifests", return_value={}):
                    for checkout in (derived.parent / "src", base / "workspace"):
                        products.stamp(derived, {"revision": "r", "xcode": "x", "architecture": "arm64",
                                                 "developer": "d", "checkout": str(checkout)})
                receipt = json.loads((derived / "Build/Products" / products.RECEIPT).read_text())
                self.assertEqual(receipt["checkout"], str(base / "workspace"))
                snippet = script[start:end].replace("/private/tmp/cmux-ci", f"{base}/private/tmp/cmux-ci")
                result = subprocess.run(
                    ["bash", "-c", "set -euo pipefail\n" + snippet + '\necho "$CMUX_CI_CANONICAL_ROOT"'],
                    env={"PATH": os.environ["PATH"], "CMUX_DERIVED_DATA_PATH": str(derived),
                         "CMUX_CI_CANONICAL_ROOT": "mine"},
                    capture_output=True, text=True, check=True)
                want = f"{base}/private/tmp/{expected}" if expected else "mine"
                self.assertEqual(result.stdout.strip(), want, slot)

    def test_only_a_successful_compile_is_kept_as_xcode_left_it(self):
        index = self.names.index
        keep = self.step("Keep this owned Mac's DerivedData")
        self.assertTrue(keep["if"].startswith("steps.hosted-compile.outcome == 'success'"))
        self.assertLess(index("Compile app-host test product"), index("Keep this owned Mac's DerivedData"))
        # Staging and packaging rewrite Build/Products and the xctestruns.
        for later in ("Stage compiled package frameworks", "Package compiled app-host test product"):
            self.assertLess(index("Keep this owned Mac's DerivedData"), index(later), later)
        self.assertTrue(self.step("Keep this owned Mac's build state")["if"].startswith("always()"))


if __name__ == "__main__":
    unittest.main()
