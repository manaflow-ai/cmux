#!/usr/bin/env python3
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
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

    def warm(self, target, slot="slot", command=None, env=None):
        return self.call(
            "warm", *self.common(slot), "--target", target, "--",
            *(command or native_command()),
            env=env,
        )

    def task(
        self,
        target,
        task_id="task",
        slot="slot",
        command=None,
        lease_id=None,
        warm_generation_id=None,
    ):
        argv = ["task-run", *self.common(slot), "--target", target, "--task-id", task_id]
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
        command = [
            sys.executable,
            "-c",
            (
                "import signal,time;"
                "signal.signal(signal.SIGTERM, lambda *_: None);"
                "print('SwiftCompile forced-kill', flush=True);"
                "time.sleep(30)"
            ),
        ]

        def request_preempt():
            # The FIFO-style pipe retains the byte until run_native installs its
            # watcher, so the test does not need to race the launch journal.
            time.sleep(0.05)
            os.write(write_fd, b"1")

        thread = threading.Thread(target=request_preempt)
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


if __name__ == "__main__":
    unittest.main()
