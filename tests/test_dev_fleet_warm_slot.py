#!/usr/bin/env python3
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "dev-fleet-warm-slot.py"
SPEC = importlib.util.spec_from_file_location("dev_fleet_warm_slot", HELPER)
assert SPEC and SPEC.loader
warm_slot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(warm_slot)

TOOLCHAIN_A = {"available": True, "platform": "darwin", "arch": "arm64", "xcode": "Xcode A", "swift": "Swift A", "sdk": "A"}
TOOLCHAIN_B = {"available": True, "platform": "darwin", "arch": "arm64", "xcode": "Xcode B", "swift": "Swift B", "sdk": "B"}


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True)
    return result.stdout.strip()


def fake_env(toolchain=TOOLCHAIN_A):
    env = os.environ.copy()
    env["CMUX_WARM_SLOT_TOOLCHAIN_JSON"] = json.dumps(toolchain)
    env["CMUX_WARM_SLOT_ALLOW_FAKE_TOOLCHAIN"] = "1"
    return env


def native_command(seconds=0.0, code=0):
    program = (
        "import sys,time;"
        "print('SwiftCompile fixture', flush=True);"
        f"time.sleep({seconds});"
        f"sys.exit({code})"
    )
    return [sys.executable, "-c", program]


def derived_data_command(code=0):
    program = (
        "import os,sys;"
        "from pathlib import Path;"
        "p=Path(os.environ['CMUX_DERIVED_DATA']);"
        "p.mkdir(parents=True, exist_ok=True);"
        "(p/'fixture.bin').write_bytes(b'x'*4096);"
        "print('SwiftCompile fixture', flush=True);"
        f"sys.exit({code})"
    )
    return [sys.executable, "-c", program]


class WarmSlotTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.name", "Warm Slot Test")
        git(self.repo, "config", "user.email", "warm-slot@example.invalid")
        (self.repo / "Sources").mkdir()
        (self.repo / "Sources" / "App.swift").write_text("let value = 1\n")
        (self.repo / "README.md").write_text("one\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")

        (self.repo / "README.md").write_text("two\n")
        git(self.repo, "add", "README.md")
        git(self.repo, "commit", "-qm", "neutral")
        self.neutral = git(self.repo, "rev-parse", "HEAD")

        (self.repo / "Sources" / "App.swift").write_text("let value = 2\n")
        git(self.repo, "add", "Sources/App.swift")
        git(self.repo, "commit", "-qm", "source")
        self.source = git(self.repo, "rev-parse", "HEAD")

        (self.repo / "Package.swift").write_text("// swift-tools-version: 6.0\n")
        git(self.repo, "add", "Package.swift")
        git(self.repo, "commit", "-qm", "graph")
        self.graph = git(self.repo, "rev-parse", "HEAD")

        (self.repo / "scripts").mkdir()
        (self.repo / "scripts" / "custom.txt").write_text("unknown\n")
        git(self.repo, "add", "scripts/custom.txt")
        git(self.repo, "commit", "-qm", "unknown")
        self.unknown = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "switch", "--detach", self.base)
        self.state = self.root / "machine"

    def tearDown(self):
        self.temp.cleanup()

    def call(self, *args, env=None, accepted=(0, 75, 130)):
        result = subprocess.run(
            [sys.executable, str(HELPER), *args],
            cwd=ROOT,
            env=env or fake_env(),
            text=True,
            capture_output=True,
            timeout=30,
        )
        self.assertIn(result.returncode, accepted, msg=result.stderr + result.stdout)
        return json.loads(result.stdout)

    def common(self, slot="slot"):
        return ["--machine-state", str(self.state), "--slot", slot, "--checkout", str(self.repo)]

    def warm(self, target, slot="slot", command=None, env=None, measure_disk=False):
        argv = ["warm", *self.common(slot), "--target", target]
        if measure_disk:
            argv.append("--measure-disk")
        argv += ["--", *(command or native_command())]
        return self.call(*argv, env=env)

    def task(
        self,
        target,
        task_id="task",
        slot="slot",
        command=None,
        lease_id=None,
        warm_generation_id=None,
        measure_disk=False,
    ):
        argv = ["task-run", *self.common(slot), "--target", target, "--task-id", task_id]
        if measure_disk:
            argv.append("--measure-disk")
        if lease_id:
            argv += ["--lease-id", lease_id]
        if warm_generation_id:
            argv += ["--warm-generation-id", warm_generation_id]
        argv += ["--", *(command or native_command())]
        return self.call(*argv)

    def test_filesystem_identifiers_are_closed_before_path_use(self):
        self.assertEqual(warm_slot.slot_id("slot-01"), "slot-01")
        self.assertEqual(warm_slot.task_id("agent:task_01"), "agent:task_01")
        for value in ("../escape", "slot/child", ".", "..", "é"):
            with self.subTest(slot=value):
                with self.assertRaises((ValueError, argparse.ArgumentTypeError)):
                    warm_slot.Layout(self.state, value)
                with self.assertRaises(argparse.ArgumentTypeError):
                    warm_slot.slot_id(value)
        for value in ("../escape", "task/child", ".", "..", "é"):
            with self.subTest(task_id=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    warm_slot.task_id(value)

    def test_cli_rejects_traversal_identifiers_before_state_creation(self):
        cases = [
            [
                "plan",
                "--machine-state", str(self.state),
                "--slot", "../escape",
                "--checkout", str(self.repo),
                "--target", self.base,
            ],
            [
                "task-run",
                "--machine-state", str(self.state),
                "--slot", "slot",
                "--checkout", str(self.repo),
                "--target", self.base,
                "--task-id", "../escape",
                "--", *native_command(),
            ],
        ]
        for argv in cases:
            with self.subTest(argv=argv):
                result = subprocess.run(
                    [sys.executable, str(HELPER), *argv],
                    cwd=ROOT,
                    env=fake_env(),
                    text=True,
                    capture_output=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("closed ASCII identifier", result.stderr)
        self.assertFalse((self.state / "escape").exists())
        self.assertFalse((self.state / "slots").exists())

    def test_log_tokens_never_embed_untrusted_path_syntax(self):
        token = warm_slot.log_token("refs/heads/feature/task")
        self.assertRegex(token, r"^[0-9a-f]{12}$")
        self.assertNotIn("/", token)
        self.assertEqual(
            warm_slot.log_token("a" * 40),
            "a" * 12,
        )

    def test_classifier_fails_toward_rebuild(self):
        neutral = warm_slot.classify(self.repo, self.base, self.neutral)
        self.assertEqual(neutral["decision"], "rebuild")
        self.assertEqual(neutral["reason"], "source_tree_changed")
        self.assertEqual(warm_slot.classify(self.repo, self.neutral, self.source)["decision"], "rebuild")
        self.assertEqual(warm_slot.classify(self.repo, self.graph, self.unknown)["decision"], "rebuild")

    def test_exact_generation_and_task_base(self):
        warmed = self.warm(self.base)
        self.assertEqual(warmed["status"], "warmed")
        selected = self.call(
            "task-base", *self.common(), "--authoritative-main", self.base,
            "--task-id", "task",
            "--receipt", str(self.root / "base-receipt.json"),
        )
        self.assertEqual(selected["status"], "warm_base")
        self.assertEqual(selected["base_commit"], self.base)
        self.assertEqual(selected["warm_generation_id"], warmed["generation"]["generation_id"])
        self.assertTrue(selected["lease_id"])
        self.assertTrue((self.root / "base-receipt.json").exists())

        built = self.task(
            self.base,
            lease_id=selected["lease_id"],
            warm_generation_id=selected["warm_generation_id"],
        )
        self.assertEqual(built["receipt"]["match_class"], "exact")
        self.assertFalse(built["receipt"]["cold_fallback"])
        self.assertEqual(built["receipt"]["swift_compile_count"], 1)

        planned = self.call("plan", *self.common(), "--target", self.base)
        self.assertEqual(planned["reason"], "slot_needs_rewarm")

    def test_recursive_disk_measurement_is_explicit(self):
        default_warm = self.warm(self.base, slot="default-disk")
        self.assertEqual(default_warm["status"], "warmed")
        for field in ("disk_bytes_before", "disk_bytes_after", "disk_growth_bytes"):
            self.assertNotIn(field, default_warm["receipt"])

        measured_warm = self.warm(self.base, slot="measured-disk", measure_disk=True)
        self.assertEqual(measured_warm["status"], "warmed")
        for field in ("disk_bytes_before", "disk_bytes_after", "disk_growth_bytes"):
            self.assertIn(field, measured_warm["receipt"])

        default_task = self.task(self.base, slot="default-disk", task_id="default-task")
        self.assertEqual(default_task["status"], "success")
        for field in ("disk_bytes_before", "disk_bytes_after", "disk_growth_bytes"):
            self.assertNotIn(field, default_task["receipt"])

        measured_task = self.task(
            self.base,
            slot="measured-disk",
            task_id="measured-task",
            measure_disk=True,
        )
        self.assertEqual(measured_task["status"], "success")
        for field in ("disk_bytes_before", "disk_bytes_after", "disk_growth_bytes"):
            self.assertIn(field, measured_task["receipt"])

    def test_reserved_generation_change_forces_cold_task_build(self):
        warmed = self.warm(self.base)
        selected = self.call(
            "task-base", *self.common(), "--authoritative-main", self.base,
            "--task-id", "reserved-generation",
        )
        self.assertEqual(
            selected["warm_generation_id"],
            warmed["generation"]["generation_id"],
        )

        record_path = self.state / "slots/slot/slot.json"
        record = json.loads(record_path.read_text())
        record["generation"]["generation_id"] = "advanced-generation"
        record_path.write_text(json.dumps(record))

        built = self.task(
            self.base,
            task_id="reserved-generation",
            lease_id=selected["lease_id"],
            warm_generation_id=selected["warm_generation_id"],
        )
        self.assertEqual(built["status"], "success")
        self.assertTrue(built["receipt"]["cold_fallback"])
        self.assertIsNone(built["receipt"]["warm_generation_id"])
        self.assertEqual(
            built["receipt"]["reserved_generation_id"],
            selected["warm_generation_id"],
        )

    def test_reserved_slot_blocks_warmer_until_task_consumes_it(self):
        self.warm(self.base)
        selected = self.call(
            "task-base", *self.common(), "--authoritative-main", self.base,
            "--task-id", "reserved",
        )
        self.assertEqual(selected["status"], "warm_base")
        lease = json.loads((self.state / "slots/slot/lease.json").read_text())
        self.assertEqual(lease["kind"], "reserved-task")
        self.assertEqual(lease["lease_id"], selected["lease_id"])

        deferred = self.warm(self.neutral)
        self.assertEqual(deferred["status"], "deferred")
        self.assertEqual(deferred["reason"], "slot_reserved")

        built = self.task(
            self.base,
            task_id="reserved",
            lease_id=selected["lease_id"],
            warm_generation_id=selected["warm_generation_id"],
        )
        self.assertEqual(built["status"], "success")
        self.assertEqual(built["receipt"]["reservation_lease_id"], selected["lease_id"])
        self.assertFalse((self.state / "slots/slot/lease.json").exists())

    def test_reservation_mismatch_fails_closed_and_release_is_exact(self):
        self.warm(self.base)
        selected = self.call(
            "task-base", *self.common(), "--authoritative-main", self.base,
            "--task-id", "reserved",
        )
        mismatch = self.task(
            self.base,
            task_id="reserved",
            lease_id="wrong",
            warm_generation_id=selected["warm_generation_id"],
        )
        self.assertEqual(mismatch["status"], "cold_fallback_required")
        self.assertEqual(mismatch["reason"], "reservation_mismatch")

        missing_generation = self.task(
            self.base,
            task_id="reserved",
            lease_id=selected["lease_id"],
        )
        self.assertEqual(missing_generation["status"], "cold_fallback_required")
        self.assertEqual(missing_generation["reason"], "generation_mismatch")

        wrong_generation = self.task(
            self.base,
            task_id="reserved",
            lease_id=selected["lease_id"],
            warm_generation_id="wrong-generation",
        )
        self.assertEqual(wrong_generation["status"], "cold_fallback_required")
        self.assertEqual(wrong_generation["reason"], "generation_mismatch")

        wrong_release = self.call(
            "release",
            "--machine-state", str(self.state),
            "--slot", "slot",
            "--task-id", "reserved",
            "--lease-id", "wrong",
        )
        self.assertEqual(wrong_release["status"], "blocked")
        released = self.call(
            "release",
            "--machine-state", str(self.state),
            "--slot", "slot",
            "--task-id", "reserved",
            "--lease-id", selected["lease_id"],
        )
        self.assertEqual(released["status"], "released")
        self.assertFalse((self.state / "slots/slot/lease.json").exists())

    def test_task_base_rejects_stale_warm_generation(self):
        self.warm(self.base)
        selected = self.call(
            "task-base", *self.common(), "--authoritative-main", self.neutral,
            "--task-id", "stale", "--max-main-distance", "0",
        )
        self.assertEqual(selected["status"], "cold")
        self.assertEqual(selected["reason"], "warm_generation_stale")
        self.assertEqual(selected["distance_to_main"], 1)

    def test_task_base_counts_only_first_parent_commits(self):
        self.warm(self.base)

        git(self.repo, "switch", "-q", "-c", "side", self.base)
        for index in range(3):
            (self.repo / f"side-{index}.txt").write_text(f"{index}\n")
            git(self.repo, "add", f"side-{index}.txt")
            git(self.repo, "commit", "-qm", f"side {index}")

        git(self.repo, "switch", "-q", "-c", "authoritative", self.neutral)
        git(self.repo, "merge", "--no-ff", "-qm", "merge side", "side")
        authoritative = git(self.repo, "rev-parse", "HEAD")

        self.assertGreater(warm_slot.distance(self.repo, self.base, authoritative), 2)
        self.assertEqual(warm_slot.first_parent_distance(self.repo, self.base, authoritative), 2)
        selected = self.call(
            "task-base", *self.common(), "--authoritative-main", authoritative,
            "--task-id", "merge-distance", "--max-main-distance", "2",
        )
        self.assertEqual(selected["status"], "warm_base")
        self.assertEqual(selected["distance_to_main"], 2)

    def test_expired_reservation_releases_slot_to_warmer(self):
        self.warm(self.base)
        selected = self.call(
            "task-base", *self.common(), "--authoritative-main", self.base,
            "--task-id", "expired",
        )
        self.assertEqual(selected["status"], "warm_base")
        lease_path = self.state / "slots/slot/lease.json"
        lease = json.loads(lease_path.read_text())
        lease["expires_epoch"] = 0
        lease_path.write_text(json.dumps(lease))

        warmed = self.warm(self.neutral)
        self.assertEqual(warmed["status"], "warmed")
        self.assertEqual(warmed["generation"]["source_commit"], self.neutral)

    def test_recover_clears_stale_active_lease_without_inflight_child(self):
        slot = self.state / "slots/slot"
        slot.mkdir(parents=True)
        lease_path = slot / "lease.json"
        lease_path.write_text(json.dumps({
            "schema_version": 1,
            "lease_id": "stale",
            "kind": "task",
            "owner": "dead-task",
            "pid": 2147483647,
            "target_commit": self.base,
        }))
        recovered = self.call(
            "recover",
            "--machine-state", str(self.state),
            "--slot", "slot",
            "--run-id", "no-native-run",
        )
        self.assertEqual(recovered["status"], "recovered")
        self.assertEqual(recovered["reason"], "stale_active_lease")
        self.assertFalse(lease_path.exists())

    def test_stale_task_lease_keeps_cold_generation_until_exact_group_settles(self):
        layout = warm_slot.Layout(self.state.resolve(), "slot")
        layout.slot.mkdir(parents=True, exist_ok=True)
        generation = "9" * 32
        active = warm_slot.cold_task_root(layout, generation)
        (active / "DerivedData").mkdir(parents=True)
        (active / "DerivedData/fixture.bin").write_bytes(b"x")
        outside = self.root / "lease-supplied-path-must-survive"
        outside.mkdir()
        outside_marker = outside / "marker"
        outside_marker.write_text("keep")
        warm_slot.atomic_json(layout.lease, {
            "schema_version": 1,
            "lease_id": "stale-native",
            "kind": "task",
            "owner": "dead-task",
            "pid": 2147483647,
            "target_commit": self.base,
            "native_run_id": "exact-run",
            "native_process_group": 424242,
            "cold_task_generation_id": generation,
            "derived_data_path": str(outside),
        })
        args = argparse.Namespace(machine_state=self.state, slot="slot", run_id="exact-run")

        with mock.patch.object(warm_slot, "group_alive", return_value=True):
            blocked = warm_slot.recover(args)
        self.assertEqual(blocked["status"], "blocked")
        self.assertEqual(blocked["reason"], "process_group_alive")
        self.assertTrue(active.exists())
        self.assertTrue(layout.lease.exists())

        wrong = argparse.Namespace(machine_state=self.state, slot="slot", run_id="wrong-run")
        with mock.patch.object(warm_slot, "group_alive", return_value=False):
            mismatch = warm_slot.recover(wrong)
        self.assertEqual(mismatch["status"], "blocked")
        self.assertEqual(mismatch["reason"], "run_id_mismatch")
        self.assertTrue(active.exists())

        with mock.patch.object(warm_slot, "group_alive", return_value=False):
            recovered = warm_slot.recover(args)
        self.assertEqual(recovered["status"], "recovered")
        self.assertEqual(recovered["cold_cache_retirement"], "retired")
        self.assertFalse(active.exists())
        self.assertTrue(warm_slot.retired_cold_task_root(layout, generation).exists())
        self.assertEqual(outside_marker.read_text(), "keep")

    def test_tree_change_runs_native_warmer(self):
        first = self.warm(self.base)
        second = self.warm(self.neutral)
        self.assertEqual(first["status"], "warmed")
        self.assertEqual(second["status"], "warmed")
        self.assertEqual(second["generation"]["source_commit"], self.neutral)
        self.assertEqual(second["generation"]["native_validated_commit"], self.neutral)
        self.assertNotEqual(
            first["generation"]["build_input_fingerprint"],
            second["generation"]["build_input_fingerprint"],
        )

    def test_toolchain_change_invalidates(self):
        first = self.warm(self.base, env=fake_env(TOOLCHAIN_A))
        planned = self.call("plan", *self.common(), "--target", self.base, env=fake_env(TOOLCHAIN_B))
        self.assertEqual(planned["decision"], "cold")
        self.assertEqual(planned["reason"], "toolchain_changed")
        second = self.warm(self.base, env=fake_env(TOOLCHAIN_B))
        self.assertEqual(second["status"], "warmed")
        self.assertNotEqual(
            first["generation"]["lineage_id"],
            second["generation"]["lineage_id"],
        )

    def test_stale_foreground_pid_identity_does_not_block_warming(self):
        foreground = self.state / "foreground"
        foreground.mkdir(parents=True)
        request = foreground / "stale.json"
        request.write_text(json.dumps({
            "schema_version": 1,
            "task_id": "stale",
            "target_commit": self.base,
            "pid": os.getpid(),
            "process_identity": "definitely-not-this-process",
        }))
        explained = self.call("explain", *self.common(), "--target", self.base)
        self.assertEqual(explained["foreground_requests"][0]["state"], "stale")
        warmed = self.warm(self.base)
        self.assertEqual(warmed["status"], "warmed")

    def test_dirty_source_quarantines_warmer(self):
        self.warm(self.base)
        (self.repo / "dirty.txt").write_text("dirty\n")
        result = self.warm(self.base)
        self.assertEqual(result["status"], "deferred")
        self.assertEqual(result["reason"], "dirty_source")
        record = json.loads((self.state / "slots/slot/slot.json").read_text())
        self.assertTrue(record["generation"]["quarantined"])

    def test_uninitialized_task_has_complete_cold_fallback(self):
        result = self.task(self.base)
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["receipt"]["match_class"], "cold")
        self.assertTrue(result["receipt"]["cold_fallback"])
        self.assertIn("cold-tasks", result["receipt"]["derived_data_path"])

    def test_settled_cold_task_is_retired_then_reclaimed(self):
        result = self.task(
            self.base,
            task_id="cold-retire",
            command=derived_data_command(),
        )
        receipt = result["receipt"]
        generation = receipt["cold_task_generation_id"]
        self.assertRegex(generation, r"^[0-9a-f]{32}$")
        self.assertEqual(receipt["cold_cache_retirement"], "retired")
        self.assertGreaterEqual(receipt["cold_cache_retirement_seconds"], 0.0)

        active = self.state / "slots/slot/cache/cold-tasks" / generation
        retired = self.state / "slots/slot/cache/retired-cold-tasks" / generation
        self.assertFalse(active.exists())
        self.assertTrue((retired / "DerivedData/fixture.bin").exists())

        cleanup = self.call(
            "cleanup",
            "--machine-state", str(self.state),
            "--slot", "slot",
            "--max-generations", "1",
            "--measure-bytes",
        )
        self.assertEqual(cleanup["status"], "reclaimed")
        self.assertEqual(cleanup["reclaimed"], 1)
        self.assertEqual(cleanup["reclaimed_bytes"], 4096)
        self.assertGreaterEqual(cleanup["wall_seconds"], 0.0)
        self.assertFalse(retired.exists())

    def test_repeated_cold_fallbacks_leave_no_active_generations_and_reap_in_bounds(self):
        active_root = self.state / "slots/slot/cache/cold-tasks"
        retired_root = self.state / "slots/slot/cache/retired-cold-tasks"
        generations = set()

        for index in range(4):
            result = self.task(
                self.base,
                task_id=f"cold-repeat-{index}",
                command=derived_data_command(),
            )
            receipt = result["receipt"]
            self.assertEqual(result["status"], "success")
            self.assertEqual(receipt["cold_cache_retirement"], "retired")
            generations.add(receipt["cold_task_generation_id"])
            self.assertEqual(list(active_root.iterdir()), [])

        self.assertEqual(len(generations), 4)
        self.assertEqual({path.name for path in retired_root.iterdir()}, generations)

        layout = warm_slot.Layout(self.state.resolve(), "slot")
        first = warm_slot.cleanup_retired_cold_tasks(layout, max_generations=2)
        self.assertEqual(first["status"], "reclaimed")
        self.assertEqual(first["reclaimed"], 2)
        self.assertEqual(len(list(retired_root.iterdir())), 2)
        self.assertEqual(list(active_root.iterdir()), [])

        second = warm_slot.cleanup_retired_cold_tasks(layout, max_generations=2)
        self.assertEqual(second["status"], "reclaimed")
        self.assertEqual(second["reclaimed"], 2)
        self.assertEqual(list(retired_root.iterdir()), [])

    def test_cleanup_never_selects_warm_shared_lineage_derived_data(self):
        warmed = self.warm(self.base, command=derived_data_command())
        self.assertEqual(warmed["status"], "warmed")
        warm_derived = Path(warmed["generation"]["derived_data_path"])
        sentinel = warm_derived / "warm-shared-sentinel"
        sentinel.write_text("keep")

        layout = warm_slot.Layout(self.state.resolve(), "slot")
        retired = warm_slot.retired_cold_task_root(layout, "8" * 32)
        (retired / "DerivedData").mkdir(parents=True)
        (retired / "DerivedData/fixture.bin").write_bytes(b"x")

        cleanup = warm_slot.cleanup_retired_cold_tasks(layout, max_generations=1)
        self.assertEqual(cleanup["status"], "reclaimed")
        self.assertTrue(warm_derived.exists())
        self.assertEqual(sentinel.read_text(), "keep")

    def test_warmer_reclaims_retired_cold_task_before_background_build(self):
        result = self.task(
            self.base,
            task_id="cold-auto-reap",
            command=derived_data_command(),
        )
        generation = result["receipt"]["cold_task_generation_id"]
        retired = self.state / "slots/slot/cache/retired-cold-tasks" / generation
        self.assertTrue(retired.exists())

        warmed = self.warm(self.base)
        self.assertEqual(warmed["status"], "warmed")
        self.assertFalse(retired.exists())

    def test_recovery_retires_exact_durable_cold_generation(self):
        layout = warm_slot.Layout(self.state, "slot")
        layout.slot.mkdir(parents=True, exist_ok=True)
        generation = "a" * 32
        decoy_generation = "b" * 32
        active = warm_slot.cold_task_root(layout, generation)
        decoy = warm_slot.cold_task_root(layout, decoy_generation)
        (active / "DerivedData").mkdir(parents=True)
        (active / "DerivedData/fixture.bin").write_bytes(b"x")
        (decoy / "DerivedData").mkdir(parents=True)
        (decoy / "DerivedData/fixture.bin").write_bytes(b"keep")
        warm_slot.atomic_json(layout.inflight, {
            "schema_version": 1,
            "run_id": "cold-recovery",
            "operation": "task:cold-recovery",
            "process_group": 2147483647,
            "cold_task_generation_id": generation,
        })

        recovered = self.call(
            "recover",
            "--machine-state", str(self.state),
            "--slot", "slot",
            "--run-id", "cold-recovery",
        )
        self.assertEqual(recovered["status"], "recovered")
        self.assertEqual(recovered["cold_cache_retirement"], "retired")
        self.assertFalse(active.exists())
        self.assertTrue(warm_slot.retired_cold_task_root(layout, generation).exists())
        self.assertTrue(decoy.exists())
        self.assertFalse(
            warm_slot.retired_cold_task_root(layout, decoy_generation).exists()
        )

    def test_cold_recovery_required_retains_generation_until_exact_recovery(self):
        program = (
            "import os,subprocess,sys;"
            "from pathlib import Path;"
            "p=Path(os.environ['CMUX_DERIVED_DATA']);"
            "p.mkdir(parents=True, exist_ok=True);"
            "(p/'fixture.bin').write_bytes(b'x');"
            "subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)']);"
            "print('SwiftCompile descendant', flush=True)"
        )
        result = self.task(
            self.base,
            task_id="cold-recovery-required",
            command=[sys.executable, "-c", program],
        )
        receipt = result["receipt"]
        generation = receipt["cold_task_generation_id"]
        active = self.state / "slots/slot/cache/cold-tasks" / generation
        retired = self.state / "slots/slot/cache/retired-cold-tasks" / generation

        self.assertEqual(result["status"], "recovery_required")
        self.assertEqual(
            receipt["cold_cache_retirement"],
            "deferred_recovery_required",
        )
        self.assertTrue(active.exists())
        self.assertFalse(retired.exists())

        inflight = json.loads(
            (self.state / "slots/slot/inflight.json").read_text()
        )
        pgid = inflight["process_group"]
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        deadline = time.time() + 5
        while time.time() < deadline and warm_slot.group_alive(pgid):
            time.sleep(0.05)

        recovered = self.call(
            "recover",
            "--machine-state", str(self.state),
            "--slot", "slot",
            "--run-id", inflight["run_id"],
        )
        self.assertEqual(recovered["status"], "recovered")
        self.assertEqual(recovered["cold_cache_retirement"], "retired")
        self.assertFalse(active.exists())
        self.assertTrue(retired.exists())

    def test_cold_retirement_rejects_untrusted_identity(self):
        layout = warm_slot.Layout(self.state, "slot")
        outside = self.root / "must-survive"
        outside.mkdir()
        marker = outside / "marker"
        marker.write_text("keep")
        result = warm_slot.retire_cold_task(layout, "../must-survive")
        self.assertEqual(result["status"], "invalid_identity")
        self.assertEqual(marker.read_text(), "keep")

    def test_retirement_and_cleanup_reject_symlink_path_confusion(self):
        generation = "7" * 32

        active_layout = warm_slot.Layout(self.state.resolve(), "active-slot")
        active_layout.cache.mkdir(parents=True)
        outside_active = self.root / "outside-active"
        outside_generation = outside_active / generation
        (outside_generation / "DerivedData").mkdir(parents=True)
        active_marker = outside_generation / "DerivedData/marker"
        active_marker.write_text("keep")
        (active_layout.cache / "cold-tasks").symlink_to(
            outside_active,
            target_is_directory=True,
        )
        retirement = warm_slot.retire_cold_task(active_layout, generation)
        self.assertEqual(retirement["status"], "invalid_namespace")
        self.assertEqual(retirement["reason"], "active_namespace_path_confusion")
        self.assertEqual(active_marker.read_text(), "keep")

        retired_layout = warm_slot.Layout(self.state.resolve(), "retired-slot")
        retired_layout.cache.mkdir(parents=True)
        outside_retired = self.root / "outside-retired"
        outside_retired.mkdir()
        victim = outside_retired / generation
        victim.mkdir()
        retired_marker = victim / "marker"
        retired_marker.write_text("keep")
        retired_layout.retired_cold_tasks.symlink_to(
            outside_retired,
            target_is_directory=True,
        )
        cleanup = warm_slot.cleanup_retired_cold_tasks(
            retired_layout,
            max_generations=1,
        )
        self.assertEqual(cleanup["status"], "failed")
        self.assertEqual(cleanup["reason"], "retired_namespace_path_confusion")
        self.assertEqual(retired_marker.read_text(), "keep")

        final_layout = warm_slot.Layout(self.state.resolve(), "final-slot")
        final_layout.retired_cold_tasks.mkdir(parents=True)
        outside_final = self.root / "outside-final"
        outside_final.mkdir()
        final_marker = outside_final / "marker"
        final_marker.write_text("keep")
        warm_slot.retired_cold_task_root(final_layout, generation).symlink_to(
            outside_final,
            target_is_directory=True,
        )
        final_cleanup = warm_slot.cleanup_retired_cold_tasks(
            final_layout,
            max_generations=1,
        )
        self.assertEqual(final_cleanup["status"], "failed")
        self.assertEqual(final_cleanup["reason"], "cleanup_generation_path_confusion")
        self.assertEqual(final_marker.read_text(), "keep")

    def test_descriptor_cleanup_unlinks_symlink_without_touching_target(self):
        layout = warm_slot.Layout(self.state.resolve(), "fd-cleanup-slot")
        generation = "6" * 32
        retired = warm_slot.retired_cold_task_root(layout, generation)
        retired.mkdir(parents=True)
        nested = retired / "nested"
        nested.mkdir()
        (nested / "fixture.bin").write_bytes(b"x")

        outside = self.root / "fd-cleanup-outside"
        outside.mkdir()
        marker = outside / "marker"
        marker.write_text("keep")
        (retired / "escape").symlink_to(outside, target_is_directory=True)

        fd = os.open(retired, warm_slot._DIRECTORY_OPEN_FLAGS)
        try:
            warm_slot._remove_tree_contents_fd(fd)
        finally:
            os.close(fd)

        self.assertEqual(marker.read_text(), "keep")
        self.assertEqual(list(retired.iterdir()), [])

    def test_cleanup_budget_is_bounded_and_unknown_entries_are_preserved(self):
        layout = warm_slot.Layout(self.state, "slot")
        unknown = layout.retired_cold_tasks / "operator-data"
        unknown.mkdir(parents=True)
        marker = unknown / "marker"
        marker.write_text("keep")

        result = warm_slot.cleanup_retired_cold_tasks(
            layout,
            max_generations=33,
        )
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["reason"], "invalid_cleanup_budget")
        self.assertEqual(marker.read_text(), "keep")

        valid = warm_slot.retired_cold_task_root(layout, "c" * 32)
        valid.mkdir(parents=True)
        (valid / "fixture.bin").write_bytes(b"x")
        result = warm_slot.cleanup_retired_cold_tasks(
            layout,
            max_generations=1,
        )
        self.assertEqual(result["status"], "reclaimed")
        self.assertFalse(valid.exists())
        self.assertEqual(marker.read_text(), "keep")

    def test_cleanup_failure_does_not_block_later_generation(self):
        layout = warm_slot.Layout(self.state, "slot")
        failed = warm_slot.retired_cold_task_root(layout, "d" * 32)
        removable = warm_slot.retired_cold_task_root(layout, "e" * 32)
        for root in (failed, removable):
            root.mkdir(parents=True)
            (root / "fixture.bin").write_bytes(b"x")

        class FakeCleanup:
            def __init__(self, generation):
                self.generation = generation
                self.pid = 2147483647
                self.returncode = None

            def wait(self, timeout=None):
                if self.generation == removable.name:
                    (removable / "fixture.bin").unlink()
                    self.returncode = 0
                else:
                    self.returncode = 1
                return self.returncode

        def launch(_generation_fd, generation):
            return FakeCleanup(generation)

        with mock.patch.object(warm_slot, "_launch_cleanup_worker", side_effect=launch):
            result = warm_slot.cleanup_retired_cold_tasks(
                layout,
                max_generations=2,
            )

        self.assertEqual(result["status"], "reclaimed")
        self.assertEqual(result["reclaimed"], 1)
        self.assertTrue(failed.exists())
        self.assertFalse(removable.exists())
        self.assertIn(
            {
                "cold_task_generation_id": failed.name,
                "reason": "cleanup_failed",
            },
            result["failures"],
        )

    def test_background_cleanup_yields_to_foreground_signal(self):
        layout = warm_slot.Layout(self.state, "slot")
        generation = "b" * 32
        retired = warm_slot.retired_cold_task_root(layout, generation)
        retired.mkdir(parents=True)
        (retired / "fixture.bin").write_bytes(b"x")

        class FakeCleanup:
            pid = 2147483647

            def __init__(self):
                self.returncode = None
                self.finished = threading.Event()

            def wait(self, timeout=None):
                self.finished.wait(timeout)
                if not self.finished.is_set():
                    raise subprocess.TimeoutExpired(["/bin/rm"], timeout)
                self.returncode = -signal.SIGTERM
                return self.returncode

            def finish(self, _pid, _signal):
                self.finished.set()

        fake_cleanup = FakeCleanup()
        read_fd, write_fd = os.pipe()
        try:
            os.write(write_fd, b"1")
            with mock.patch.object(
                warm_slot,
                "_launch_cleanup_worker",
                return_value=fake_cleanup,
            ):
                with mock.patch.object(
                    warm_slot.os,
                    "killpg",
                    side_effect=fake_cleanup.finish,
                ):
                    result = warm_slot.cleanup_retired_cold_tasks(
                        layout,
                        preempt_fd=read_fd,
                        max_generations=1,
                    )
        finally:
            os.close(read_fd)
            os.close(write_fd)

        self.assertEqual(result["status"], "preempted")
        self.assertTrue(retired.exists())

        resumed = warm_slot.cleanup_retired_cold_tasks(
            layout,
            max_generations=1,
        )
        self.assertEqual(resumed["status"], "reclaimed")
        self.assertEqual(resumed["reclaimed"], 1)
        self.assertFalse(retired.exists())
        repeated = warm_slot.cleanup_retired_cold_tasks(
            layout,
            max_generations=1,
        )
        self.assertEqual(repeated["status"], "idle")
        self.assertEqual(repeated["reclaimed"], 0)

    def test_same_checkout_serializes_different_slots(self):
        slow = native_command(seconds=1.5)
        first = subprocess.Popen(
            [
                sys.executable, str(HELPER), "task-run", *self.common("one"),
                "--target", self.base, "--task-id", "one", "--", *slow,
            ],
            cwd=ROOT,
            env=fake_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        lease = self.state / "slots/one/lease.json"
        deadline = time.time() + 5
        while time.time() < deadline and not lease.exists():
            time.sleep(0.05)
        self.assertTrue(lease.exists())
        second = self.task(self.base, task_id="two", slot="two", command=native_command())
        stdout, stderr = first.communicate(timeout=10)
        self.assertEqual(first.returncode, 0, msg=stderr + stdout)
        self.assertEqual(second["status"], "success")

        events = [
            json.loads(line)
            for line in (self.state / "events.jsonl").read_text().splitlines()
            if line.strip()
        ]
        finished = [
            row["receipt"]["task_id"]
            for row in events
            if row.get("event") == "task_finished"
        ]
        self.assertEqual(finished[-2:], ["one", "two"])

    def test_machine_warmer_lock_and_visible_lease(self):
        slow = [
            sys.executable, "-c",
            "import time; print('SwiftCompile slow', flush=True); time.sleep(20)",
        ]
        proc = subprocess.Popen(
            [
                sys.executable, str(HELPER), "warm", *self.common("one"),
                "--target", self.base, "--", *slow,
            ],
            cwd=ROOT,
            env=fake_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        lease = self.state / "slots/one/lease.json"
        deadline = time.time() + 5
        while time.time() < deadline and not lease.exists():
            time.sleep(0.05)
        self.assertTrue(lease.exists())
        self.assertEqual(json.loads(lease.read_text())["kind"], "warmer")
        second = self.warm(self.base, slot="two")
        self.assertEqual(second["status"], "deferred")
        self.assertEqual(second["reason"], "warmer_already_running")
        proc.terminate()
        proc.communicate(timeout=15)

    def test_real_task_preempts_warmer_and_quarantines(self):
        slow = [
            sys.executable, "-c",
            "import time; print('SwiftCompile warmer', flush=True); time.sleep(20)",
        ]
        proc = subprocess.Popen(
            [
                sys.executable, str(HELPER), "warm", *self.common(),
                "--target", self.base, "--", *slow,
            ],
            cwd=ROOT,
            env=fake_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        lease = self.state / "slots/slot/lease.json"
        deadline = time.time() + 5
        while time.time() < deadline:
            if lease.exists() and json.loads(lease.read_text()).get("kind") == "warmer":
                break
            time.sleep(0.05)
        self.assertTrue(lease.exists())
        task = self.task(self.base, task_id="foreground", command=native_command())
        stdout, stderr = proc.communicate(timeout=15)
        self.assertEqual(task["status"], "success")
        self.assertTrue(task["receipt"]["warmer_in_flight_at_task_known"])
        self.assertTrue(task["receipt"]["cold_fallback"])
        warm_result = json.loads(stdout)
        self.assertEqual(warm_result["status"], "yielded", msg=stderr)
        record = json.loads((self.state / "slots/slot/slot.json").read_text())
        self.assertTrue(record["generation"]["quarantined"])

    def test_forced_kill_still_requires_observed_process_group_settlement(self):
        layout = warm_slot.Layout(self.state, "slot")
        layout.slot.mkdir(parents=True, exist_ok=True)
        layout.logs.mkdir(parents=True, exist_ok=True)
        read_fd, write_fd = os.pipe()
        ready = layout.slot / "forced-kill-ready.fifo"
        os.mkfifo(ready)
        command = [
            sys.executable,
            "-c",
            (
                "import signal,sys,time;"
                "signal.signal(signal.SIGTERM, lambda *_: None);"
                "open(sys.argv[1], 'w').close();"
                "print('SwiftCompile forced-kill', flush=True);"
                "time.sleep(30)"
            ),
            str(ready),
        ]

        def request_preempt():
            # The forced kill only happens when the child outlives TERM_GRACE,
            # which it only does once it has installed its SIGTERM handler.
            # Opening the FIFO rendezvous blocks until the child has done so,
            # where a fixed sleep raced interpreter startup and left the run
            # dying on the default SIGTERM action instead. The pipe itself
            # retains the byte until run_native installs its watcher.
            with open(ready, "r"):
                pass
            os.write(write_fd, b"1")

        # Daemon so a child that never reaches the rendezvous fails the
        # assertions instead of wedging the suite on a blocked open().
        thread = threading.Thread(target=request_preempt, daemon=True)
        thread.start()
        try:
            with (
                warm_slot.visible_lease(layout, "warmer", "fixture", self.base),
                mock.patch.object(warm_slot, "TERM_GRACE_SECONDS", 0.01),
                mock.patch.object(warm_slot, "group_alive", return_value=True),
            ):
                result = warm_slot.run_native(
                    layout,
                    self.repo,
                    command,
                    fake_env(),
                    layout.logs / "forced-kill.log",
                    "warm",
                    True,
                    False,
                    read_fd,
                )
        finally:
            thread.join(timeout=5)
            os.close(read_fd)
            os.close(write_fd)

        self.assertEqual(result["outcome"], "recovery_required")
        self.assertTrue(result["force_killed"])
        self.assertTrue(layout.inflight.exists())

    def test_interrupted_run_requires_exact_recovery(self):
        slow = [
            sys.executable, "-c",
            "import time; print('SwiftCompile crash', flush=True); time.sleep(30)",
        ]
        proc = subprocess.Popen(
            [
                sys.executable, str(HELPER), "warm", *self.common(),
                "--target", self.base, "--", *slow,
            ],
            cwd=ROOT,
            env=fake_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        inflight_path = self.state / "slots/slot/inflight.json"
        deadline = time.time() + 5
        while time.time() < deadline and not inflight_path.exists():
            time.sleep(0.05)
        self.assertTrue(inflight_path.exists())
        inflight = json.loads(inflight_path.read_text())
        while inflight.get("process_group") is None and time.time() < deadline:
            time.sleep(0.05)
            inflight = json.loads(inflight_path.read_text())
        os.kill(proc.pid, signal.SIGKILL)
        proc.communicate(timeout=5)
        pgid = inflight["process_group"]
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                os.killpg(pgid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)

        planned = self.call("plan", *self.common(), "--target", self.base)
        self.assertEqual(planned["reason"], "recovery_required")
        wrong = self.call(
            "recover", "--machine-state", str(self.state), "--slot", "slot", "--run-id", "wrong"
        )
        self.assertEqual(wrong["reason"], "run_id_mismatch")
        recovered = self.call(
            "recover", "--machine-state", str(self.state), "--slot", "slot",
            "--run-id", inflight["run_id"]
        )
        self.assertEqual(recovered["status"], "recovered")
        self.assertTrue(recovered["cold_lineage_required"])

    def test_unreadable_inflight_without_backup_fails_closed(self):
        self.warm(self.base)
        slot = self.state / "slots/slot"
        (slot / "inflight.json").write_text("{")
        recovered = self.call(
            "recover",
            "--machine-state", str(self.state),
            "--slot", "slot",
            "--run-id", "repair-unreadable",
        )
        self.assertEqual(recovered["status"], "blocked")
        self.assertEqual(
            recovered["reason"],
            "unreadable_inflight_without_durable_child_identity",
        )
        self.assertTrue((slot / "inflight.json").exists())

    def test_unreadable_inflight_with_durable_backup_recovers_cold(self):
        self.warm(self.base)
        slot = self.state / "slots/slot"
        (slot / "inflight.json").write_text("{")
        (slot / "lease.json").write_text(json.dumps({
            "schema_version": 1,
            "lease_id": "native-backup",
            "kind": "warmer",
            "owner": "dead-warmer",
            "pid": 2147483647,
            "target_commit": self.base,
            "native_run_id": "repair-unreadable",
            "native_process_group": 2147483647,
            "native_launch_guard": "pipe_v1",
        }))
        recovered = self.call(
            "recover",
            "--machine-state", str(self.state),
            "--slot", "slot",
            "--run-id", "repair-unreadable",
        )
        self.assertEqual(recovered["status"], "recovered")
        self.assertTrue(recovered["cold_lineage_required"])
        self.assertTrue(recovered["unreadable_inflight"])
        record = json.loads((slot / "slot.json").read_text())
        self.assertTrue(record["generation"]["quarantined"])

    def test_corrupt_state_fails_closed(self):
        slot = self.state / "slots/slot"
        slot.mkdir(parents=True)
        (slot / "slot.json").write_text("{")
        result = self.call("plan", *self.common(), "--target", self.base)
        self.assertEqual(result["decision"], "fallback")
        self.assertEqual(result["reason"], "state_unreadable")

    def test_event_journal_bounds_growth_without_fsync(self):
        layout = warm_slot.Layout(self.state, "slot")
        max_bytes = 1024
        with (
            mock.patch.object(warm_slot, "EVENT_JOURNAL_MAX_BYTES", max_bytes),
            mock.patch.object(warm_slot.os, "fsync", side_effect=AssertionError("telemetry must not fsync")),
        ):
            for index in range(500):
                warm_slot.event(layout, "high_rate", index=index, payload="x" * 64)

        retained = []
        paths = [layout.events_archive, layout.events]
        for path in paths:
            self.assertTrue(path.exists())
            self.assertLessEqual(path.stat().st_size, max_bytes + 512)
            for line in path.read_text().splitlines():
                retained.append(json.loads(line))
        self.assertEqual(retained[-1]["index"], 499)
        self.assertLessEqual(sum(path.stat().st_size for path in paths), 2 * (max_bytes + 512))

    def test_event_journal_repairs_partial_tail_before_rotation(self):
        layout = warm_slot.Layout(self.state, "slot")
        layout.events.parent.mkdir(parents=True, exist_ok=True)
        complete = json.dumps(
            {"event": "kept", "index": 1, "payload": "x" * 256},
            sort_keys=True,
        ) + "\n"
        layout.events.write_bytes(complete.encode() + b'{"event":"partial"')

        with mock.patch.object(warm_slot, "EVENT_JOURNAL_MAX_BYTES", len(complete.encode()) + 64):
            warm_slot.event(layout, "after_crash", index=2)

        self.assertEqual(layout.events_archive.read_text(), complete)
        current = [json.loads(line) for line in layout.events.read_text().splitlines()]
        self.assertEqual([row["event"] for row in current], ["after_crash"])
        self.assertEqual(current[0]["index"], 2)

    def test_event_journal_recovers_archive_only_and_recreates_after_deletion(self):
        layout = warm_slot.Layout(self.state, "slot")
        layout.events.parent.mkdir(parents=True, exist_ok=True)
        archived = json.dumps({"event": "before_crash"}, sort_keys=True) + "\n"
        layout.events_archive.write_text(archived)

        warm_slot.event(layout, "after_restart")
        self.assertEqual(layout.events_archive.read_text(), archived)
        self.assertEqual(json.loads(layout.events.read_text())["event"], "after_restart")

        layout.events.unlink()
        layout.events_archive.unlink()
        warm_slot.event(layout, "after_deletion")
        self.assertEqual(json.loads(layout.events.read_text())["event"], "after_deletion")

    def test_event_journal_concurrent_high_rate_appends_are_complete(self):
        layout = warm_slot.Layout(self.state, "slot")
        threads = []
        workers = 8
        per_worker = 50

        def append(worker: int) -> None:
            for index in range(per_worker):
                warm_slot.event(layout, "concurrent", worker=worker, index=index)

        for worker in range(workers):
            thread = threading.Thread(target=append, args=(worker,))
            threads.append(thread)
            thread.start()
        for thread in threads:
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive())

        rows = [json.loads(line) for line in layout.events.read_text().splitlines()]
        self.assertEqual(len(rows), workers * per_worker)
        self.assertEqual(
            {(row["worker"], row["index"]) for row in rows},
            {(worker, index) for worker in range(workers) for index in range(per_worker)},
        )

    def test_event_journal_retries_partial_os_writes(self):
        layout = warm_slot.Layout(self.state, "slot")
        real_write = os.write

        def partial_write(fd, data):
            chunk = bytes(data[:max(1, len(data) // 2)])
            return real_write(fd, chunk)

        with mock.patch.object(warm_slot.os, "write", side_effect=partial_write):
            warm_slot.event(layout, "partial_write", index=7)

        row = json.loads(layout.events.read_text())
        self.assertEqual(row["event"], "partial_write")
        self.assertEqual(row["index"], 7)

    def test_event_journal_drops_row_larger_than_retention_budget(self):
        layout = warm_slot.Layout(self.state, "slot")
        with mock.patch.object(warm_slot, "EVENT_JOURNAL_MAX_BYTES", 64):
            warm_slot.event(layout, "oversized", payload="x" * 128)
        self.assertFalse(layout.events.exists())

    def test_event_io_failure_is_observational(self):
        layout = warm_slot.Layout(self.state, "slot")
        with mock.patch.object(warm_slot, "_append_event_line", side_effect=OSError("telemetry unavailable")):
            warm_slot.event(layout, "dropped")


if __name__ == "__main__":
    unittest.main()
