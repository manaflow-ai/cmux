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
    def test_check_records_the_seed_prefix_for_idle_prefetch(self):
        env = {"RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64", "CI_CACHE_R2_PUBLIC_URL": "https://cache.test"}
        with unittest.mock.patch.dict(os.environ, env):
            run(state.check, self.store, "fp", self.workspace)
        recorded = json.loads((self.store / state.seed.SEED_SOURCE).read_text())
        self.assertEqual(recorded, {"prefix": "admission-derived-data-v1-macOS-ARM64-fp-", "runner_os": "macOS",
                                    "runner_arch": "ARM64", "public_url": "https://cache.test"})
        # Outside a job there is nothing to record.
        (self.store / state.seed.SEED_SOURCE).unlink()
        with unittest.mock.patch.dict(os.environ, {"RUNNER_OS": ""}):
            run(state.check, self.store, "fp", self.workspace)
        self.assertFalse((self.store / state.seed.SEED_SOURCE).exists())

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


A = "a" * 40
B = "b" * 40
C = "c" * 40
D = "d" * 40
E = "e" * 40


class WarmKeys(Fixture):
    """`keep` stamps the merge base; `warm-keys` prints what owned_warm_state.py folds."""

    def setUp(self):
        super().setUp()
        self.seeds = self.store / "seeds"

    def kept(self, fingerprint="fp", merged_onto=A, pr="", store=None):
        self.derived.mkdir(parents=True, exist_ok=True)
        return run(state.keep, store or self.store, self.derived, fingerprint, merged_onto, pr)

    def seed(self, commit, fingerprint="fp", jobs=14, when=0, manifest=True):
        path = self.seeds / f"admission-derived-data-v1-macOS-ARM64-{fingerprint}-j{jobs}-{commit}"
        path.mkdir(parents=True)
        if manifest:
            (path / state.seed.MANIFEST).write_text("{}")
        os.utime(path, (1_000_000 + when, 1_000_000 + when))
        return path

    def keys(self, fingerprint="fp", cache=True):
        env = {"CMUX_SEED_LOCAL_CACHE": str(self.seeds) if cache else ""}
        with unittest.mock.patch.dict(os.environ, env):
            return state.warm_keys(self.store, "cmux11s-glaeda-1", "glaeda-root-std-xcode-26.6", fingerprint)

    def test_keep_stamps_the_merge_base_and_replaces_it(self):
        self.kept(merged_onto=A.upper())
        self.assertEqual(json.loads((self.store / "stamp.json").read_text())["merged_onto"], A)
        self.kept(merged_onto="")
        self.assertNotIn("merged_onto", json.loads((self.store / "stamp.json").read_text()))
        self.kept(merged_onto="not-a-commit")
        self.assertNotIn("merged_onto", json.loads((self.store / "stamp.json").read_text()))

    def test_kept_build_first_then_the_newest_seeds_of_this_fingerprint(self):
        self.kept()
        self.seed(B, when=10)
        self.seed(C, when=30, jobs=12)
        self.seed(D, when=20)
        self.seed(E, fingerprint="other", when=40)  # another Xcode: never adopted here
        self.seed("f" * 40, when=50, manifest=False)  # incomplete
        self.assertEqual(self.keys(), {"runner": "cmux11s-glaeda-1", "pool": "glaeda-root-std-xcode-26.6",
                                       "keys": ["a" * 12, "c" * 12, "d" * 12, "b" * 12]})

    def test_at_most_eight_keys_without_repeats(self):
        self.kept()
        commits = (A, B, C, D, E, *(f"{digit}" * 40 for digit in range(5)))
        for when, commit in enumerate(commits):
            self.seed(commit, when=when)
        self.assertEqual(self.keys()["keys"], ["a" * 12, *(f"{digit}" * 12 for digit in (4, 3, 2, 1, 0)),
                                               "e" * 12, "d" * 12])
        self.assertEqual(state.MAX_WARM_KEYS, __import__("owned_warm_state").MAX_KEYS)

    def test_keep_stamps_the_pull_request_after_the_merge_base(self):
        self.kept(pr="14718")
        self.assertEqual(json.loads((self.store / "stamp.json").read_text())["pr"], 14718)
        self.seed(B)
        self.assertEqual(self.keys()["keys"], ["a" * 12, "pr-14718", "b" * 12])
        for junk in ("", "0", "x1", "1" * 10):
            self.kept(pr=junk)
            self.assertNotIn("pr", json.loads((self.store / "stamp.json").read_text()), junk)
        output = io.StringIO()
        with unittest.mock.patch("sys.stdout", output):
            self.assertEqual(state.main(["x", "keep", str(self.store), str(self.derived), "fp", A, "7"]), 0)
        self.assertEqual(json.loads((self.store / "stamp.json").read_text())["pr"], 7)

    def test_the_other_roots_keys_follow_this_roots(self):
        # A job's root follows glaeda's free token, so a runner lists its whole mini.
        # Each root has its own fingerprint (compile-app-host-test-product.sh adds root=).
        second = self.store / "cmux-ci-2"
        self.kept(pr="7")
        self.kept(fingerprint="fp2", merged_onto=B, pr="8", store=second)
        self.seed(C)
        self.assertEqual(self.keys()["keys"], ["a" * 12, "pr-7", "b" * 12, "pr-8", "c" * 12])
        with unittest.mock.patch.dict(os.environ, {"CMUX_SEED_LOCAL_CACHE": ""}):
            from_second = state.warm_keys(second, "r", "p", "fp2")["keys"]
        self.assertEqual(from_second, ["b" * 12, "pr-8", "a" * 12, "pr-7"])
        # Another root counts only with a kept DerivedData of this STATE_VERSION.
        stamp = json.loads((second / "stamp.json").read_text())
        (second / "stamp.json").write_text(json.dumps({**stamp, "fingerprint": "fp2-owned-rec0"}))
        self.assertEqual(self.keys()["keys"], ["a" * 12, "pr-7", "c" * 12])
        (second / "stamp.json").write_text(json.dumps(stamp))
        state.clear(second / "derived-data")
        self.assertEqual(self.keys()["keys"], ["a" * 12, "pr-7", "c" * 12])
        # Not a root store: never read.
        (self.store / "cmux-ci-x").mkdir()
        self.assertEqual(state.other_root_stores(self.store), [second])

    def test_seeds_count_only_when_prefer_may_clone_them(self):
        self.kept()
        self.seed(B)
        self.assertEqual(self.keys(cache=False)["keys"], ["a" * 12])

    def test_a_kept_build_of_another_fingerprint_or_none_is_not_warm(self):
        self.seed(B)
        self.assertEqual(self.keys()["keys"], ["b" * 12])
        self.kept(fingerprint="old")
        self.assertEqual(self.keys(fingerprint="fp")["keys"], ["b" * 12])
        self.assertEqual(self.keys(fingerprint="")["keys"], ["a" * 12, "b" * 12])

    def test_a_kept_build_without_a_merge_base_adds_no_key(self):
        self.kept(merged_onto="")
        self.assertEqual(self.keys()["keys"], [])

    def test_main_prints_only_the_document_the_janitor_folds(self):
        import owned_warm_state

        self.kept()
        self.seed(B)
        output = io.StringIO()
        with unittest.mock.patch("sys.stdout", output), \
             unittest.mock.patch.dict(os.environ, {"CMUX_SEED_LOCAL_CACHE": str(self.seeds),
                                                   "GITHUB_OUTPUT": str(self.store / "out")}):
            self.assertEqual(state.main(["x", "warm-keys", str(self.store), "cmux11s-glaeda-1",
                                         "glaeda-root-std-xcode-26.6", "fp"]), 0)
        document = json.loads(output.getvalue())
        self.assertFalse((self.store / "out").exists())
        jobs = [{"name": "CI / " + owned_warm_state.ADMISSION_JOB, "runner_name": "cmux11s-glaeda-1",
                 "workflow_name": owned_warm_state.CI_WORKFLOW}]
        self.assertEqual(owned_warm_state.record(document, jobs), ("cmux11s-glaeda-1", ["a" * 12, "b" * 12]))

    def test_main_never_fails(self):
        output = io.StringIO()
        with unittest.mock.patch("sys.stdout", output), \
             unittest.mock.patch.object(state, "warm_keys", side_effect=OSError("disk")):
            self.assertEqual(state.main(["x", "warm-keys", str(self.store), "r", "p"]), 0)
        self.assertEqual(json.loads(output.getvalue()), {"runner": "r", "pool": "p", "keys": []})

    def test_the_usage_names_warm_keys(self):
        self.assertIn("owned_build_state.py warm-keys STORE RUNNER POOL", state.__doc__)


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
        self.env = unittest.mock.patch.dict(os.environ, {"CMUX_SEED_LOCAL_CACHE": str(self.cache),
                                                          "CMUX_SEED_SWIFT_JOBS": "14"})
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
        with unittest.mock.patch.object(state.seed, "locate", return_value=located), \
             unittest.mock.patch.object(state.seed, "lineage", return_value=["base", "older", "oldest"]):
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

    def test_a_small_kept_diff_never_pays_for_a_download(self):
        """A download costs about DOWNLOAD_INPUTS inputs of compile, so 3 changed inputs keep the warm build."""
        self.kept(changed=3)
        with unittest.mock.patch.object(state, "bucket_seed_rebuilds_app", return_value=False):
            for located, limit in ((("p-j14-base", 2), None), (("p-j14-base", 2), 2), (("p-j14-base", 0), 50)):
                result = self.prefer(located, max_distance=limit)
                self.assertEqual(result["prefer"], "false")
        self.assertIn("too few to pay for a download", result["reason"])

    def test_an_unchanged_kept_derived_data_is_never_replaced_by_a_download(self):
        self.kept(changed=0)
        self.assertEqual(self.prefer(("p-j14-base", 0), max_distance=5)["prefer"], "false")

    def test_no_seed_or_no_record(self):
        self.kept(changed=3)
        self.assertEqual(self.prefer(("p-j14-base", None), max_distance=5)["prefer"], "false")
        (self.store / "derived-data" / state.RECORD).unlink()
        self.assertEqual(self.prefer(("p-j14-base", 9))["prefer"], "false")
        self.assertEqual(self.prefer(("p-j14-base", 9), max_distance=10)["prefer"], "true")
        self.kept_seed("p-j12-oldest", changed=4)
        result = self.prefer(("p-j14-base", None))
        self.assertEqual((result["prefer"], result["seed_key"]), ("true", "p-j12-oldest"))

    def test_the_nearest_kept_seed_counts_not_only_the_newest_in_the_bucket(self):
        """The bucket's nearest seed moves with every reseed; a warm Mac that
        never downloads keeps an older one, which still counts."""
        self.kept(changed=5)
        self.kept_seed("p-j14-oldest", changed=4)
        self.kept_seed("p-j12-older", changed=2)
        result = self.prefer(("p-j14-base", 0))
        self.assertEqual((result["prefer"], result["seed_key"], result["seed_distance"], result["local"]),
                         ("true", "p-j12-older", "1", "true"))
        # The adopt that follows clones exactly that seed, never a newer one.
        with unittest.mock.patch.dict(os.environ, {"CMUX_SEED_EXACT": result["seed_key"],
                                                   "CMUX_SEED_DISTANCE": result["seed_distance"]}):
            self.assertEqual(state.seed.chosen(), ("p-j12-older", 1))
        with unittest.mock.patch.dict(os.environ, {"CMUX_SEED_EXACT": "p-j14-gone"}):
            self.assertIsNone(state.seed.chosen())

    def recorded_with_package_change(self, changed):
        record = self.recorded(changed)
        record["Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/F.swift"] = ["stale", 1]
        return record

    def test_rebuilds_app_only_for_a_package_swift_source(self):
        self.assertTrue(state.rebuilds_app({"Packages/macOS/CmuxCloud/Sources/CmuxCloud/A.swift"}))
        self.assertTrue(state.rebuilds_app({"vendor/bonsplit/Package.swift"}))
        self.assertFalse(state.rebuilds_app({"Sources/AppDelegate.swift", "cmuxTests/ATests.swift",
                                             "Packages/macOS/CmuxCloud/README.md"}))

    def test_a_seed_without_a_package_change_beats_more_changed_inputs_with_one(self):
        """115 changed inputs across a package change cost 958 s (job 108004619872)."""
        self.kept(changed=5)
        (self.cache / "p-j14-base").mkdir(parents=True)
        (self.cache / "p-j14-base" / state.seed.MANIFEST).write_text(
            json.dumps(self.recorded_with_package_change(changed=1)))
        result = self.prefer()
        self.assertEqual((result["prefer"], result["seed_rebuilds_app"], result["kept_rebuilds_app"]),
                         ("false", "true", "false"))

    def test_a_nearer_bucket_seed_replaces_a_kept_seed_that_recompiles_the_app(self):
        self.kept(changed=6)
        (self.store / "derived-data" / state.RECORD).write_text(
            json.dumps(self.recorded_with_package_change(changed=6)))
        (self.cache / "p-j14-oldest").mkdir(parents=True)
        (self.cache / "p-j14-oldest" / state.seed.MANIFEST).write_text(
            json.dumps(self.recorded_with_package_change(changed=1)))
        with unittest.mock.patch.object(state, "bucket_seed_rebuilds_app", return_value=False) as compare:
            result = self.prefer(("p-j14-base", 0), max_distance=2)
        compare.assert_called_once_with("p-j14-base", self.workspace)
        self.assertEqual((result["prefer"], result["seed_key"], result["local"]), ("true", "p-j14-base", "false"))
        # When the bucket seed recompiles the app too, or GitHub cannot say,
        # the clone stays: it is the cheaper start.
        for answer in (True, None):
            with unittest.mock.patch.object(state, "bucket_seed_rebuilds_app", return_value=answer):
                result = self.prefer(("p-j14-base", 0), max_distance=2)
            self.assertEqual((result["prefer"], result["seed_key"], result["local"]), ("true", "p-j14-oldest", "true"))
        # Without downloads, the kept seed is all there is.
        with unittest.mock.patch.object(state, "bucket_seed_rebuilds_app") as compare:
            result = self.prefer(("p-j14-base", 0))
        compare.assert_not_called()
        self.assertEqual((result["prefer"], result["seed_key"]), ("true", "p-j14-oldest"))

    def test_a_far_bucket_seed_replaces_a_kept_build_that_recompiles_the_app(self):
        (self.store / "derived-data").mkdir(parents=True)
        (self.store / "derived-data" / state.RECORD).write_text(
            json.dumps(self.recorded_with_package_change(changed=3)))
        with unittest.mock.patch.object(state, "bucket_seed_rebuilds_app", return_value=False):
            result = self.prefer(("p-j14-base", 6), max_distance=2)
        self.assertEqual((result["prefer"], result["seed_key"], result["seed_distance"], result["local"]),
                         ("true", "p-j14-base", "6", "false"))
        for answer in (True, None):
            with unittest.mock.patch.object(state, "bucket_seed_rebuilds_app", return_value=answer):
                self.assertEqual(self.prefer(("p-j14-base", 6), max_distance=2)["prefer"], "false")

    def test_a_near_bucket_seed_that_recompiles_the_app_never_replaces_a_kept_build_that_does_not(self):
        self.kept(changed=state.DOWNLOAD_INPUTS + 50)
        for files, expected in ((["Packages/X/Sources/X/A.swift"], "false"), (None, "false"),
                                (["Sources/A.swift"], "true")):
            with unittest.mock.patch.object(state, "bucket_compare", return_value=files):
                result = self.prefer(("p-j14-base", 1), max_distance=2)
            self.assertEqual(result["prefer"], expected)
            if files and expected == "false":
                self.assertEqual(result["reason"],
                                 "the seed 1 commits behind may recompile the app; the kept DerivedData does not")

    def test_the_cheapest_kept_seed_wins_not_the_nearest(self):
        """The nearest kept seed sits behind a package change; an older one does not."""
        self.kept(changed=6)
        (self.cache / "p-j14-base").mkdir(parents=True)
        (self.cache / "p-j14-base" / state.seed.MANIFEST).write_text(
            json.dumps(self.recorded_with_package_change(changed=1)))
        self.kept_seed("p-j14-older", changed=3)
        result = self.prefer(("p-j14-base", 0))
        self.assertEqual((result["prefer"], result["seed_key"], result["seed_changed"], result["local"]),
                         ("true", "p-j14-older", "3", "true"))

    def test_a_far_download_wins_on_github_s_estimate_not_its_commit_count(self):
        """main moves 5 to 8 commits per seed, so a count of 2 almost never passed."""
        self.kept(changed=6)
        big = state.DOWNLOAD_INPUTS + 200
        record = self.recorded(6)
        for index in range(6, big):
            record[f"Sources/G{index}.swift"] = ["stale", 1]
        (self.store / "derived-data" / state.RECORD).write_text(json.dumps(record))
        with unittest.mock.patch.object(state, "bucket_compare", return_value=["Sources/A.swift"] * 5 + ["Sources/B.swift"]):
            result = self.prefer(("p-j14-base", 6), max_distance=50)
        self.assertEqual((result["prefer"], result["seed_key"], result["seed_changed"], result["local"]),
                         ("true", "p-j14-base", "2", "false"))
        many = [f"Sources/H{index}.swift" for index in range(big - 50)]
        with unittest.mock.patch.object(state, "bucket_compare", return_value=many):
            self.assertEqual(self.prefer(("p-j14-base", 6), max_distance=50)["prefer"], "false")
        with unittest.mock.patch.object(state, "bucket_compare", return_value=["Packages/X/Sources/X/A.swift"]):
            self.assertEqual(self.prefer(("p-j14-base", 6), max_distance=50)["prefer"], "false")
        # GitHub cannot say: no download.
        with unittest.mock.patch.object(state, "bucket_compare", return_value=None):
            self.assertEqual(self.prefer(("p-j14-base", 2), max_distance=50)["prefer"], "false")
        # A submodule bump makes the counts incomparable: only a seed a couple
        # of commits behind, and only one GitHub call either way.
        with unittest.mock.patch.object(state, "submodules", return_value={"ghostty"}):
            with unittest.mock.patch.object(state, "bucket_compare", return_value=["ghostty", "Sources/A.swift"]) as compare:
                self.assertEqual(self.prefer(("p-j14-base", 6), max_distance=50)["prefer"], "false")
                self.assertEqual(self.prefer(("p-j14-base", 2), max_distance=50)["prefer"], "true")
            self.assertEqual(compare.call_count, 2)
        # MAX_DISTANCE still caps a download.
        with unittest.mock.patch.object(state, "bucket_compare", return_value=["Sources/A.swift"]):
            self.assertEqual(self.prefer(("p-j14-base", 6), max_distance=5)["prefer"], "false")

    def test_a_download_is_weighed_against_the_best_kept_seed_too(self):
        big = state.DOWNLOAD_INPUTS * 3
        record = self.recorded(6)
        for index in range(6, big):
            record[f"Sources/G{index}.swift"] = ["stale", 1]
        (self.store / "derived-data").mkdir(parents=True)
        (self.store / "derived-data" / state.RECORD).write_text(json.dumps(record))
        local = self.recorded(6)
        for index in range(6, state.DOWNLOAD_INPUTS * 2):
            local[f"Sources/G{index}.swift"] = ["stale", 1]
        (self.cache / "p-j14-oldest").mkdir(parents=True)
        (self.cache / "p-j14-oldest" / state.seed.MANIFEST).write_text(json.dumps(local))
        with unittest.mock.patch.object(state, "bucket_compare", return_value=["Sources/A.swift"]):
            result = self.prefer(("p-j14-base", 4), max_distance=50)
        self.assertEqual((result["prefer"], result["seed_key"], result["local"]), ("true", "p-j14-base", "false"))
        with unittest.mock.patch.object(state, "bucket_compare",
                                        return_value=[f"Sources/H{i}.swift" for i in range(state.DOWNLOAD_INPUTS)]):
            result = self.prefer(("p-j14-base", 4), max_distance=50)
        self.assertEqual((result["prefer"], result["seed_key"], result["local"]), ("true", "p-j14-oldest", "true"))

    def test_best_kept_seed_skips_an_unreadable_manifest(self):
        self.kept(changed=5)
        (self.cache / "p-j14-base").mkdir(parents=True)
        (self.cache / "p-j14-base" / state.seed.MANIFEST).write_text("{not json")
        self.kept_seed("p-j14-older", changed=1)
        result = self.prefer(("p-j14-base", 0))
        self.assertEqual((result["prefer"], result["seed_key"]), ("true", "p-j14-older"))

    def test_a_small_kept_diff_never_asks_github(self):
        self.kept(changed=3)
        with unittest.mock.patch.object(state, "bucket_compare") as compare, \
             unittest.mock.patch.object(state, "bucket_seed_rebuilds_app", return_value=True):
            self.prefer(("p-j14-base", 6), max_distance=50)
        compare.assert_not_called()

    def test_package_tests_do_not_rebuild_the_app(self):
        self.assertFalse(state.rebuilds_app({"Packages/macOS/CmuxSettingsUI/Tests/CmuxSettingsUITests/ATests.swift"}))

    def test_a_far_bucket_seed_never_replaces_a_kept_build_without_a_package_change(self):
        self.kept(changed=3)
        with unittest.mock.patch.object(state, "bucket_seed_rebuilds_app") as compare:
            self.assertEqual(self.prefer(("p-j14-base", 6), max_distance=2)["prefer"], "false")
        compare.assert_not_called()

    def test_the_bucket_compare_reads_github_and_gives_up_past_its_file_limit(self):
        def run(files):
            def fake(argv, **_):
                out = "abc123\n" if argv[0] == "git" else json.dumps(files)
                return unittest.mock.Mock(stdout=out)
            return fake
        with unittest.mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "o/r"}):
            with unittest.mock.patch.object(state.subprocess, "run", side_effect=run(["Sources/A.swift"])) as ran:
                self.assertIs(state.bucket_seed_rebuilds_app("p-j14-seedsha", self.workspace), False)
            self.assertEqual(ran.call_args_list[1].args[0][:3], ["gh", "api", "repos/o/r/compare/seedsha...abc123"])
            with unittest.mock.patch.object(state.subprocess, "run", side_effect=run(["Packages/X/Sources/X/A.swift"])):
                self.assertIs(state.bucket_seed_rebuilds_app("p-j14-seedsha", self.workspace), True)
            with unittest.mock.patch.object(state.subprocess, "run", side_effect=run(["Sources/A.swift"] * 300)):
                self.assertIsNone(state.bucket_seed_rebuilds_app("p-j14-seedsha", self.workspace))
            with unittest.mock.patch.object(state.subprocess, "run", side_effect=OSError("no gh")):
                self.assertIsNone(state.bucket_seed_rebuilds_app("p-j14-seedsha", self.workspace))
        with unittest.mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": ""}):
            self.assertIsNone(state.bucket_seed_rebuilds_app("p-j14-seedsha", self.workspace))

    def test_a_submodule_bump_under_a_package_root_rebuilds_the_app(self):
        """Compare lists a submodule bump as the bare path (bonsplit, 4 bumps this month)."""
        (self.workspace / ".gitmodules").write_text(
            '[submodule "vendor/bonsplit"]\n\tpath = vendor/bonsplit\n\turl = x\n'
            '[submodule "ghostty"]\n\tpath = ghostty\n\turl = y\n')
        self.assertEqual(state.submodules(self.workspace), {"vendor/bonsplit", "ghostty"})
        real = state.subprocess.run

        def fake(argv, **kwargs):
            if argv[:2] == ["git", "-C"]:
                return unittest.mock.Mock(stdout="abc123\n")
            if argv[0] == "gh":
                return unittest.mock.Mock(stdout=json.dumps(self.compared))
            return real(argv, **kwargs)
        with unittest.mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "o/r"}), \
             unittest.mock.patch.object(state.subprocess, "run", side_effect=fake):
            self.compared = ["vendor/bonsplit"]
            self.assertIs(state.bucket_seed_rebuilds_app("p-j14-seedsha", self.workspace), True)
            # ghostty ships as a prebuilt xcframework, not a package root.
            self.compared = ["ghostty", "Sources/A.swift"]
            self.assertIs(state.bucket_seed_rebuilds_app("p-j14-seedsha", self.workspace), False)

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
        # check, prefer, adopt, record, keep, warm-keys, save.
        self.assertEqual(len(calls), 7)
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / "derived").mkdir()
            env = {"PATH": "/usr/bin:/bin", "CMUX_OWNED_STATE_ROOT": str(base / "store"),
                   "CMUX_COMPILE_ADMISSION_DERIVED_DATA": str(base / "derived"),
                   "CMUX_CI_CANONICAL_SRC": str(base / "src"), "FINGERPRINT": "fp",
                   "MERGED_ONTO": "a" * 40, "RUNNER_NAME": "runner", "RUNNER_TEMP": str(base),
                   "CMUX_PRODUCT_RUNNER": "glaeda-root-std-xcode-26.6", "HOME": str(base)}
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
            # keep ran before warm-keys, so the kept build's merge base is listed.
            self.assertEqual(json.loads((base / "warm-keys.json").read_text())["keys"], ["a" * 12])


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
        # Main's full-suite dispatch may be placed on an owned Mac too (pr_runner_pool.py).
        self.assertIn("github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'",
                      self.by_id["owned-state"]["if"])
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
            self.assertIn("steps.prefer-seed.outputs.seed_key", step["env"]["CMUX_SEED_EXACT"])
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
                     "Keep this owned Mac's build state", "List the commits this owned Mac starts from warm",
                     "Upload the owned Mac's warm keys"):
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


class E2EWiring(unittest.TestCase):
    """test-e2e.yml's build reads the owned state admission keeps, and never writes it."""

    def setUp(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/test-e2e.yml").read_text())
        self.jobs = workflow["jobs"]
        self.steps = self.jobs["build"]["steps"]
        self.names = [step.get("name") for step in self.steps]
        self.by_id = {step.get("id"): step for step in self.steps if step.get("id")}

    def test_state_is_read_only_on_an_owned_runner(self):
        owned = self.by_id["owned-state"]
        self.assertIn(OWNED, owned["if"])
        self.assertIn("steps.reuse.outputs.hit != 'true'", owned["if"])
        self.assertIn("steps.owned-state.outputs.warm == 'true'", self.by_id["prefer-seed"]["if"])
        self.assertIn("vars.CI_OWNED_PREFER_SEED != ''", self.by_id["prefer-seed"]["if"])
        self.assertIn("steps.owned-state.outputs.warm == 'true'", self.by_id["owned-adopt"]["if"])
        for step_id in ("owned-state", "prefer-seed", "owned-adopt"):
            self.assertIs(self.by_id[step_id].get("continue-on-error"), True, step_id)
            self.assertNotIn("uses", self.by_id[step_id], step_id)
        # A dispatch builds any revision it names, so it must never become
        # the next pull request's starting point: check, prefer and adopt
        # only, in every job of the workflow.
        import re
        text = (ROOT / ".github/workflows/test-e2e.yml").read_text()
        commands = re.findall(r"owned_build_state\.py\" ([a-z-]+)", text)
        self.assertEqual(sorted(set(commands)), ["adopt", "check", "prefer"])
        for word in ("keep", "save", "record", "warm-keys"):
            self.assertNotRegex(text, rf"owned_build_state\.py\"? {word}\b")

    def test_a_failed_adopt_starts_the_build_empty(self):
        # adopt's copytree fallback leaves a partial tree when it fails, and
        # the step continues on error, so the compile would trust it.
        discard = self.steps[self.names.index("Discard a partly adopted DerivedData")]
        self.assertEqual(discard["if"], "${{ steps.owned-adopt.outcome == 'failure' }}")
        self.assertIn('rm -rf -- "$CMUX_DERIVED_DATA_PATH"', discard["run"])
        self.assertIn("refusing to clear an unowned DerivedData path", discard["run"])
        index = self.names.index
        self.assertEqual(index("Adopt this owned Mac's DerivedData") + 1, index(discard["name"]))
        self.assertLess(index(discard["name"]), index("Build the app-host and UI test product"))

    def test_the_helper_comes_from_the_workflow_revision(self):
        # An older tested revision's owned_build_state.py moved the kept state
        # out of the store for a keep this job never runs.
        run = self.by_id["owned-state"]["run"]
        self.assertEqual(self.by_id["owned-state"]["env"]["WORKFLOW_SHA"], "${{ github.workflow_sha }}")
        self.assertIn("raw.githubusercontent.com/$GITHUB_REPOSITORY/$WORKFLOW_SHA/scripts/ci/$name", run)
        for step_id in ("owned-state", "prefer-seed", "owned-adopt"):
            self.assertNotIn("scripts/ci/owned_build_state.py", str(self.by_id[step_id]), step_id)
        # Naming it as scripts/ci/... in the build job would make the tested
        # revision's copy part of the E2E product identity.
        import product_input_identity as identity
        block = identity._job_block(identity.Path(ROOT / ".github/workflows/test-e2e.yml").read_text(), "build")
        self.assertNotIn("scripts/ci/owned_build_state.py", block)

    def test_owned_packages_and_state_skip_the_downloads(self):
        self.assertIn("steps.owned-state.outputs.packages != 'true'", self.by_id["swift-package-cache"]["if"])
        for step in (self.by_id["seed"], self.step("Start the DerivedData seed download")):
            self.assertIn("steps.owned-state.outputs.warm != 'true' || steps.prefer-seed.outputs.prefer == 'true'",
                          step["if"])
            # Empty off an owned Mac, so Blacksmith's seed steps see no local cache.
            self.assertEqual(step["env"]["CMUX_SEED_LOCAL_CACHE"],
                             "${{ vars.CI_OWNED_PREFER_SEED != '' && steps.owned-state.outputs.seeds || '' }}")
            self.assertIn("steps.prefer-seed.outputs.seed_key", step["env"]["CMUX_SEED_EXACT"])
        self.assertIn("steps.seed.outputs.hit != 'true'", self.by_id["owned-adopt"]["if"])
        self.assertIn("steps.owned-adopt.outcome != 'skipped'",
                      self.step("Forget the adopted-build inode override")["if"])

    def step(self, name):
        return self.steps[self.names.index(name)]

    def test_order(self):
        index = self.names.index
        self.assertLess(index("Reuse a compiled product instead of building one"), index("Reuse this owned Mac's build state"))
        self.assertLess(index("Reuse this owned Mac's build state"), index("Cache Swift packages"))
        self.assertLess(index("Compute the DerivedData seed key"), index("Prefer a near seed over this owned Mac's DerivedData"))
        self.assertLess(index("Prefer a near seed over this owned Mac's DerivedData"), index("Start the DerivedData seed download"))
        self.assertLess(index("Resolve Swift packages"), index("Adopt this owned Mac's DerivedData"))
        self.assertLess(index("Adopt the DerivedData seed"), index("Adopt this owned Mac's DerivedData"))
        self.assertLess(index("Adopt this owned Mac's DerivedData"), index("Build the app-host and UI test product"))
        self.assertIn('"$CMUX_CI_CANONICAL_SRC"', self.by_id["owned-adopt"]["run"])

    def owned_state(self, root, kept_packages=True):
        """Run the owned-state step against a temporary store; (code, outputs, store base)."""
        import os
        import subprocess
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        fleet, workspace, temp = base / "fleet", base / "workspace", base / "temp"
        for directory in (fleet, workspace / "scripts/ci", temp, base / "bin"):
            directory.mkdir(parents=True)
        if kept_packages:
            (fleet / "source-packages").mkdir()
            (fleet / "source-packages" / "Package.resolved").write_text("kept")
        fingerprint = workspace / "scripts/ci/compile-app-host-test-product.sh"
        fingerprint.write_text("#!/bin/sh\necho fp\n")
        fingerprint.chmod(0o755)
        # Serve the helpers from this checkout and record what was asked for.
        curl = base / "bin" / "curl"
        curl.write_text(f"""#!/bin/sh
while [ "$#" -gt 1 ]; do
  case "$1" in -o) out="$2"; shift ;; esac
  shift
done
echo "$1" >> "{base}/urls"
cp "{ROOT}/scripts/ci/${{1##*/}}" "$out"
""")
        curl.chmod(0o755)
        output = base / "output"
        output.write_text("")
        run = self.by_id["owned-state"]["run"].replace("/Users/Shared/cmux-build-fleet/ci", str(fleet))
        env = {"PATH": f"{base / 'bin'}:{os.environ['PATH']}", "GITHUB_OUTPUT": str(output),
               "RUNNER_TEMP": str(temp), "GITHUB_REPOSITORY": "manaflow-ai/cmux", "WORKFLOW_SHA": "w" * 40,
               "CMUX_DERIVED_DATA_PATH": "/private/tmp/cmux-ci/derived-data-compile-admission", "HOME": str(base)}
        if root is not None:
            env["CMUX_CI_CANONICAL_ROOT"] = root
        result = subprocess.run(["bash", "-e", "-c", run], cwd=workspace, env=env, capture_output=True, text=True)
        outputs = dict(line.split("=", 1) for line in output.read_text().splitlines())
        urls = (base / "urls").read_text().split() if (base / "urls").exists() else []
        return result, outputs, fleet, workspace, urls

    def test_each_root_reads_its_own_state_and_the_macs_packages(self):
        for root, suffix in ((None, ""), ("/private/tmp/cmux-ci", ""), ("/private/tmp/cmux-ci-2", "/cmux-ci-2")):
            with self.subTest(root=root):
                result, outputs, fleet, workspace, urls = self.owned_state(root)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(outputs["store"], f"{fleet}{suffix}")
                self.assertEqual(outputs["seeds"], f"{fleet}{suffix}/seeds")
                self.assertEqual(outputs["warm"], "false")
                self.assertEqual(outputs["packages"], "true")
                self.assertEqual((workspace / ".ci-source-packages/Package.resolved").read_text(), "kept")
                # A clone: the Mac's packages stay where they were.
                self.assertEqual((fleet / "source-packages/Package.resolved").read_text(), "kept")
                self.assertTrue(urls)
                for url in urls:
                    self.assertTrue(url.startswith(f"https://raw.githubusercontent.com/manaflow-ai/cmux/{'w' * 40}/scripts/ci/"), url)
                self.assertTrue(Path(outputs["tools"], "owned_build_state.py").is_file())

    def test_an_unexpected_root_reads_nothing(self):
        for root in ("/tmp/elsewhere", "/private/tmp/cmux-ci-x", "/private/tmp/cmux-ci/../x"):
            with self.subTest(root=root):
                result, outputs, _, workspace, urls = self.owned_state(root)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(outputs, {})
                self.assertEqual(urls, [])
                self.assertFalse((workspace / ".ci-source-packages").exists())

    def test_the_adopt_and_prefer_lines_are_ones_the_script_accepts(self):
        import os
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / "derived").mkdir()
            env = {"PATH": "/usr/bin:/bin", "HOME": str(base), "OWNED_TOOLS": str(ROOT / "scripts/ci"),
                   "OWNED_STORE": str(base / "store"), "CMUX_DERIVED_DATA_PATH": str(base / "derived"),
                   "CMUX_CI_CANONICAL_SRC": str(base / "src"), "SEED_PREFIX": "p-", "TEST_REF": "base",
                   "MAX_DISTANCE": "", "CMUX_SEED_LOCAL_CACHE": str(base / "store/seeds")}
            for step_id in ("owned-adopt", "prefer-seed"):
                script = self.by_id[step_id]["run"].replace("python3 ", f"{sys.executable} ")
                result = subprocess.run(["bash", "-c", script], cwd=base, env=dict(env, GITHUB_OUTPUT=os.devnull),
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, f"{step_id}: {result.stderr[-400:]}")
                self.assertNotIn("owned_build_state.py check STORE", result.stderr, step_id)


if __name__ == "__main__":
    unittest.main()
