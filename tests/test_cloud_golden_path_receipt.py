#!/usr/bin/env python3
"""Focused tests for the Cloud golden-path receipt validator."""
from __future__ import annotations

import copy
import importlib.util
import json
import random
import shutil
import string
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "cmux-next" / "cloud_golden_path_receipt.py"
SPEC = importlib.util.spec_from_file_location("cloud_golden_path_receipt", MODULE_PATH)
assert SPEC and SPEC.loader
receipt = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipt)

MACHINE = "vm_q7x2m9k4p1z8w3n6r5t0"
OTHER_MACHINE = "vm_ffff0000ffff0000ffff"
# The receipt cmuxterm-hq's writer (tools/cloud-golden-path/golden_path.run_probe, #7402 final at 8a0ff8ba) writes
# for CLI_EVIDENCE: lease and auth fail `.not_observable`, so its outcome is "failed".
CLI_FIXTURE = ROOT / "tests" / "fixtures" / "cloud_golden_path_cli_receipt.json"
# The writer as committed at 8a0ff8ba (read with `git show`, so edits in that checkout don't move it).
WRITER_REPO = Path("/home/cmux/Projects/checkouts/cmuxterm-hq/lane--golden-path-matrix")
WRITER_COMMIT = "8a0ff8ba26af"
WRITER_PATH = "tools/cloud-golden-path/golden_path.py"
# What cli_backend.CliBackend's stages answer at 8a0ff8ba, in its stage order; ("fail", code, details) raises.
CLI_EVIDENCE: dict[str, object] = {
    "machine": {"machineId": "vm_q7x2m9k4p1z8w3n6r5t0", "workspace": "start-matrix-golden-path", "created": True},
    "readiness": {
        "state": "running",
        "tunnel": {"connected": True, "stage": "ready", "daemon": "connected", "ms": 4200},
        "guest": {"host": "cmux-vm", "image_stamp": "2026-11-06T04:00Z", "vm_kind": "cloud", "cmux_host": "active",
                  "daemon_version": "0.64.2", "daemon_commit": "a1b2c3d", "protocol": 3, "compatibility": "full",
                  "daemon_machine_id": "vm_q7x2m9k4p1z8w3n6r5t0", "ms": 900, "identified": True},
        "exec": {"request_id": "start-matrix-golden-path:readiness", "echoed": True, "ms": 300},
    },
    "lease": ("fail", "lease.not_observable",
              {"receiver_policy": {"journal_read": True, "admission": ["present"], "policy_read_ms": [3, 4]}}),
    "folder": {"from_folder": True, "codeword_read_back": True, "files": 1, "reply_ms": 2100},
    "auth": ("fail", "auth.not_observable", {"ownership": {"signed_in": True, "listed": True, "status": "running"}}),
    "chat": {"session_id": "sess_acp_1", "reply_ms": 1800, "discovery_ms": 400, "session_discovered": True},
    "reconnect": {
        "pause": {"state": "paused", "ms": 12000}, "resume": {"state": "running", "ms": 30000},
        "link": {"dropped_while_paused": True, "back": True, "back_ms": 2500},
        "second_reply": {"ok": True, "ms": 1700}, "reconnected": True,
    },
}
# A receipt shaped exactly as cmux-platform#927's runner (scripts/golden-path-probe.ts, d32eddc0) writes it:
# runGoldenPath's JSON for the same machine, with lease {machineId, connectionMachine, generation} and auth
# {allowed}; reconnect always fails reconnect.not_observable (the probe no longer pauses or resumes).
PLATFORM_FIXTURE = ROOT / "tests" / "fixtures" / "cloud_golden_path_platform_receipt.json"


def writer_receipt(writer, evidence: dict[str, object] = CLI_EVIDENCE) -> dict[str, object]:
    """The receipt WRITER's run_probe writes for EVIDENCE, on a fixed clock."""
    def call(value):
        def run(_request_id):
            if isinstance(value, tuple):
                raise writer.GoldenPathFailure(value[1], value[1].split(".")[0], details=copy.deepcopy(value[2]))
            return copy.deepcopy(value)
        return run

    ticks = iter(range(1_793_000_000, 1_800_000_000))
    return writer.run_probe([writer.ProbeStage(name, call(value)) for name, value in evidence.items()],
                            probe_id="start-matrix-golden-path", now=lambda: float(next(ticks)))


def load_writer(test: unittest.TestCase):
    try:
        source = subprocess.run(
            ["git", "-C", str(WRITER_REPO), "show", f"{WRITER_COMMIT}:{WRITER_PATH}"],
            check=True, capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        test.skipTest(f"cmuxterm-hq golden-path writer at {WRITER_COMMIT} not available here")
    directory = Path(tempfile.mkdtemp())
    test.addCleanup(shutil.rmtree, directory)
    (directory / "golden_path.py").write_bytes(source)
    spec = importlib.util.spec_from_file_location("golden_path_writer", directory / "golden_path.py")
    writer = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = writer  # its dataclasses look their module up
    test.addCleanup(sys.modules.pop, spec.name, None)
    spec.loader.exec_module(writer)
    return writer
CLI_PROBE = "11111111-2222-4333-8444-555555555555"
PLATFORM_PROBE = "66666666-7777-4888-9999-aaaaaaaaaaaa"
ALL_STAGES = ("machine", "folder", "readiness", "lease", "auth", "chat", "reconnect")


def stage(name: str, second: int, ms: int, *, probe: str = CLI_PROBE, ok: bool = True,
          value: dict | None = None, failure: dict | None = None) -> dict[str, object]:
    record: dict[str, object] = {
        "stage": name,
        "requestId": f"{probe}:{name}",
        "startedAt": f"2026-11-06T18:00:{second:02d}.000Z",
        "endedAt": f"2026-11-06T18:00:{second:02d}.{ms:03d}Z",
        "ok": ok,
    }
    if value is not None:
        record["value"] = value
    if failure is not None:
        record["failure"] = failure
    return record


def failure(code: str, message: str = "boom") -> dict[str, object]:
    return {"code": code, "message": message, "retryable": False}


def golden_receipt(probe: str, stages: list[dict[str, object]], machine: str = MACHINE) -> dict[str, object]:
    failed = next((item for item in stages if not item["ok"]), None)
    value: dict[str, object] = {
        "version": 1,
        "probeId": probe,
        "startedAt": "2026-11-06T18:00:00.000Z",
        "endedAt": "2026-11-06T18:00:59.000Z",
        "outcome": "failed" if failed else "passed",
        "machineId": machine,
        "stages": stages,
    }
    if failed:
        value["failure"] = {**failed["failure"], "stage": failed["stage"]}
    return value


def cli_receipt(chat: dict | None = None, reconnect: dict | None = None) -> dict[str, object]:
    chat_value = {"session_id_chars": 10, "session_id_sha256": "0a1b2c3d4e5f", "reply_ms": 900, "discovery_ms": 40,
                  "session_discovered": True, "ms": 450}
    chat_value.update(chat or {})
    reconnect_value = {"pause": {"state": "paused", "ms": 10}, "resume": {"state": "running", "ms": 20},
                       "link": {"dropped_while_paused": True, "back": True, "back_ms": 5},
                       "reconnected": True, "second_reply": {"ok": True, "ms": 30}, "ms": 800}
    reconnect_value.update(reconnect or {})
    return golden_receipt(CLI_PROBE, [
        stage("machine", 1, 120, value={"machineId": MACHINE, "workspace": "golden-path", "created": True}),
        stage("folder", 2, 5, value={"workspace": "golden-path"}),
        stage("readiness", 3, 900, value={"state": "running", "generation": 7}),
        stage("chat", 5, 450, value={k: v for k, v in chat_value.items() if v is not None}),
        stage("reconnect", 7, 800, value={k: v for k, v in reconnect_value.items() if v is not None}),
    ])


def platform_receipt() -> dict[str, object]:
    return golden_receipt(PLATFORM_PROBE, [
        stage("lease", 10, 40, probe=PLATFORM_PROBE,
              value={"machineId": MACHINE, "connectionMachine": MACHINE, "generation": 7}),
        stage("auth", 11, 30, probe=PLATFORM_PROBE, value={"allowed": True}),
    ])


def provider(verified: object = True, machine: str = MACHINE) -> dict[str, object]:
    return {"machineId": machine, "provider_verified": verified}


def passing() -> list[dict[str, object]]:
    return [cli_receipt(), platform_receipt(), provider()]


def write_and_run(directory: str, text: str | bytes, *extra: str) -> tuple[int, dict[str, object]]:
    path = Path(directory) / "receipt.jsonl"
    if isinstance(text, bytes):
        path.write_bytes(text)
    else:
        path.write_text(text, encoding="utf-8")
    output = Path(directory) / "normalized.json"
    code = receipt.main(["--receipt", str(path), "--out", str(output), *extra])
    return code, json.loads(output.read_text())


class GoldenPathReceiptTests(unittest.TestCase):
    def assertUnsupported(self, records: list[object], message: object = None) -> dict[str, object]:
        result = receipt.normalize(records)
        self.assertNotEqual(result["status"], "pass", message)
        self.assertIn("receipt_shape_unsupported", result["blockers"], message)
        return result

    # Merging and stages.

    def test_merged_receipts_pass_with_stage_ms(self) -> None:
        result = receipt.normalize(passing())

        self.assertEqual(result["status"], "pass", result["blockers"])
        self.assertEqual(result["blockers"], [])
        self.assertEqual(result["machine_id"], MACHINE)
        self.assertEqual(result["probe_ids"], [CLI_PROBE, PLATFORM_PROBE])
        self.assertEqual(result["golden_path_stages"], {name: "ok" for name in ALL_STAGES})
        self.assertEqual(
            result["stage_ms"],
            {"machine": 120, "folder": 5, "readiness": 900, "lease": 40, "auth": 30, "chat": 450, "reconnect": 800},
        )
        self.assertTrue(all(result["checks"].values()))

    def test_empty_receipt_is_blocked(self) -> None:
        self.assertEqual(receipt.normalize([])["blockers"], ["receipt_empty"])

    def test_missing_lease_and_auth_blocks(self) -> None:
        result = receipt.normalize([cli_receipt(), provider()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("missing_stage_lease", result["blockers"])
        self.assertIn("missing_stage_auth", result["blockers"])

    def test_failed_stage_fails(self) -> None:
        denied = golden_receipt(PLATFORM_PROBE, [
            stage("lease", 10, 40, probe=PLATFORM_PROBE, value={}),
            stage("auth", 11, 30, probe=PLATFORM_PROBE, ok=False, failure=failure("auth.denied", "no chat grant")),
        ])
        result = receipt.normalize([cli_receipt(), denied, provider()])

        self.assertEqual(result["status"], "fail")
        self.assertIn("stage_failed_auth", result["blockers"])
        self.assertEqual(result["golden_path_stages"]["auth"], "failed")
        self.assertEqual(
            result["failures"],
            [{"stage": "auth", "code": "auth.denied", "probe_id": PLATFORM_PROBE, "message_length": 13}],
        )

    def test_failure_in_one_receipt_beats_ok_in_another(self) -> None:
        failed_chat = golden_receipt(PLATFORM_PROBE, [
            stage("chat", 12, 70, probe=PLATFORM_PROBE, ok=False, failure=failure("chat.error")),
        ])
        result = receipt.normalize(passing() + [failed_chat])

        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["golden_path_stages"]["chat"], "failed")

    def test_ok_stage_with_failure_object_is_unsupported(self) -> None:
        for code in ("auth.denied", "auth.not_observable", "auth.no_route"):
            platform = platform_receipt()
            platform["stages"][1]["failure"] = failure(code)
            result = self.assertUnsupported([cli_receipt(), platform, provider()], code)
            self.assertEqual(result["golden_path_stages"]["auth"], "missing", code)
            self.assertEqual(result["golden_path_stages"]["lease"], "missing", code)

    def test_stage_not_observable_blocks(self) -> None:
        cli = cli_receipt()
        cli["stages"][2] = stage("readiness", 3, 900, ok=False, failure=failure("readiness.not_observable"))
        cli["outcome"] = "failed"
        cli["failure"] = {**cli["stages"][2]["failure"], "stage": "readiness"}
        result = receipt.normalize([cli, platform_receipt(), provider()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("stage_not_observable_readiness", result["blockers"])
        self.assertEqual(result["golden_path_stages"]["readiness"], "not_observable")

    # Receipt-level failure: the receipt proves nothing positive.

    def test_receipt_level_not_observable_failure_never_passes(self) -> None:
        platform = platform_receipt()
        platform["outcome"] = "failed"
        platform["failure"] = {**failure("auth.not_observable"), "stage": "auth"}
        result = receipt.normalize([cli_receipt(), platform, provider()])

        # Its auth stage passed, so the receipt-level gap repeats no gap stage of its own: a real failure.
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["golden_path_stages"]["lease"], "missing")
        self.assertEqual(result["golden_path_stages"]["auth"], "failed")

    def test_receipt_level_failure_beside_passed_outcome_proves_nothing(self) -> None:
        platform = platform_receipt()
        platform["failure"] = {**failure("auth.denied"), "stage": "auth"}
        result = receipt.normalize([cli_receipt(), platform, provider()])

        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["golden_path_stages"]["lease"], "missing")

    def test_failed_outcome_without_failure_proves_nothing(self) -> None:
        cli = cli_receipt()
        cli["outcome"] = "failed"
        result = receipt.normalize([cli, platform_receipt(), provider()])

        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["golden_path_stages"]["chat"], "missing")

    # Provider proof, discovery and continuity evidence.

    def test_provider_proof_missing_blocks(self) -> None:
        result = receipt.normalize([cli_receipt(), platform_receipt()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("provider_proof_missing", result["blockers"])

    def test_provider_proof_rejected_fails(self) -> None:
        result = receipt.normalize([cli_receipt(), platform_receipt(), provider(False)])

        self.assertEqual(result["status"], "fail")
        self.assertIn("provider_proof_rejected", result["blockers"])

    def test_provider_proof_for_another_machine_blocks(self) -> None:
        result = receipt.normalize([cli_receipt(), platform_receipt(), provider(machine=OTHER_MACHINE)])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("machine_id_mismatch", result["blockers"])
        self.assertIn("provider_proof_missing", result["blockers"])

    def test_receipts_for_different_machines_block(self) -> None:
        other = platform_receipt()
        other["machineId"] = OTHER_MACHINE
        other["stages"][0]["value"].update(machineId=OTHER_MACHINE, connectionMachine=OTHER_MACHINE)
        result = receipt.normalize([cli_receipt(), other, provider()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("machine_id_mismatch", result["blockers"])

    def test_discovery_evidence(self) -> None:
        result = receipt.normalize([cli_receipt(chat={"session_discovered": None}), platform_receipt(), provider()])
        self.assertEqual(result["status"], "blocked")
        self.assertIn("missing_acpmux_session_discovery", result["blockers"])

        for key in ("session_id_chars", "session_id_sha256"):
            result = receipt.normalize([cli_receipt(chat={key: None}), platform_receipt(), provider()])
            self.assertEqual(result["status"], "blocked", key)
            self.assertIn("missing_acpmux_session_discovery", result["blockers"], key)
        # A raw session id is not evidence (the writer never writes one).
        result = receipt.normalize([
            cli_receipt(chat={"session_id_chars": None, "session_id_sha256": None, "session_id": "sess_acp_1"}),
            platform_receipt(), provider(),
        ])
        self.assertFalse(result["checks"]["acpmux_session_discovery"])

        result = receipt.normalize([cli_receipt(chat={"session_discovered": False}), platform_receipt(), provider()])
        self.assertEqual(result["status"], "fail")
        self.assertIn("receipt_reports_failure", result["blockers"])

    def test_continuity_evidence(self) -> None:
        for key in ("pause", "resume", "link", "reconnected", "second_reply"):
            result = receipt.normalize([cli_receipt(reconnect={key: None}), platform_receipt(), provider()])
            self.assertEqual(result["status"], "blocked", key)
            self.assertIn("missing_pause_resume_reconnect", result["blockers"], key)
        result = receipt.normalize([
            cli_receipt(reconnect={"link": {"dropped_while_paused": True, "back_ms": 5}}), platform_receipt(), provider(),
        ])
        self.assertEqual(result["status"], "blocked")
        self.assertIn("missing_pause_resume_reconnect", result["blockers"])
        for change in ({"pause": {"state": "running"}}, {"resume": {"state": "paused"}}, {"reconnected": False},
                       {"second_reply": {"ok": False, "ms": 3}},
                       {"link": {"dropped_while_paused": True, "back": False, "back_ms": 5}},
                       {"link": {"dropped_while_paused": False, "back": True, "back_ms": 5}}):
            result = receipt.normalize([cli_receipt(reconnect=change), platform_receipt(), provider()])
            self.assertEqual(result["status"], "fail", change)
            self.assertIn("receipt_reports_failure", result["blockers"], change)

    # Strict schema: any deviation makes the record unsupported and evidence-free.

    def test_schema_deviations_are_unsupported(self) -> None:
        def mutate(index: int, change) -> list[dict[str, object]]:
            records = passing()
            change(records[index])
            return records

        def drop(key):
            return lambda record: record.pop(key)

        def put(key, value):
            return lambda record: record.__setitem__(key, value)

        def stage_put(position, key, value):
            return lambda record: record["stages"][position].__setitem__(key, value)

        def value_put(position, key, value):
            return lambda record: record["stages"][position]["value"].__setitem__(key, value)

        cases = {
            "no top-level machineId": (0, drop("machineId")),
            "machine_id alias": (0, lambda r: r.__setitem__("machine_id", r.pop("machineId"))),
            "unknown top-level key": (0, put("extra", 1)),
            "version 2": (0, put("version", 2)),
            "version True": (0, put("version", True)),
            "outcome word": (0, put("outcome", "ok")),
            "uppercase machineId": (0, put("machineId", "vm_ZZ99zz99")),
            "machineId too long": (0, put("machineId", "vm_" + "a" * 65)),
            "probeId not a string": (0, put("probeId", 7)),
            "startedAt not a timestamp": (0, put("startedAt", "yesterday")),
            "stages not a list": (0, put("stages", {})),
            "failure null": (0, put("failure", None)),
            "failure empty": (0, put("failure", {})),
            "unknown stage name": (0, stage_put(0, "stage", "session.pause")),
            "unknown stage key": (0, stage_put(0, "status", "ok")),
            "ok as string": (0, stage_put(0, "ok", "true")),
            "ok as int": (0, stage_put(0, "ok", 1)),
            "missing requestId": (0, lambda r: r["stages"][0].pop("requestId")),
            "value not an object": (0, stage_put(0, "value", [])),
            "stage failure null": (0, stage_put(0, "failure", None)),
            "stage failure missing retryable": (0, stage_put(0, "failure", {"code": "machine.x", "message": "m"})),
            "stage failure extra key": (0, stage_put(0, "failure", {**failure("machine.x"), "extra": 1})),
            "session_discovered string": (0, value_put(3, "session_discovered", "true")),
            "pause not an object": (0, value_put(4, "pause", "paused")),
            "pause state not a string": (0, value_put(4, "pause", {"state": True})),
            "reconnected string": (0, value_put(4, "reconnected", "true")),
            "second_reply ok string": (0, value_put(4, "second_reply", {"ok": "true"})),
            "session_id_chars string": (0, value_put(3, "session_id_chars", "10")),
            "session_id_chars bool": (0, value_put(3, "session_id_chars", True)),
            "session_id_chars zero": (0, value_put(3, "session_id_chars", 0)),
            "session_id_chars float": (0, value_put(3, "session_id_chars", 10.5)),
            "session_id_sha256 too long": (0, value_put(3, "session_id_sha256", "0a1b2c3d4e5f6")),
            "session_id_sha256 uppercase": (0, value_put(3, "session_id_sha256", "0A1B2C3D4E5F")),
            "session_id_sha256 int": (0, value_put(3, "session_id_sha256", 12)),
            "reply_ms string": (0, value_put(3, "reply_ms", "900")),
            "discovery_ms bool": (0, value_put(3, "discovery_ms", True)),
            "chat ms string": (0, value_put(3, "ms", "1")),
            "pause ms string": (0, value_put(4, "pause", {"state": "paused", "ms": "10"})),
            "link not an object": (0, value_put(4, "link", True)),
            "link back string": (0, value_put(4, "link", {"dropped_while_paused": True, "back": "true", "back_ms": 5})),
            "link back_ms bool": (0, value_put(4, "link", {"dropped_while_paused": True, "back": True, "back_ms": True})),
            "second_reply ms string": (0, value_put(4, "second_reply", {"ok": True, "ms": "3"})),
            "reconnect ms bool": (0, value_put(4, "ms", False)),
            "lease generation bool": (1, value_put(0, "generation", True)),
            "lease generation float": (1, value_put(0, "generation", 7.5)),
            "lease machineId bad": (1, value_put(0, "machineId", "VM_1")),
            "lease connectionMachine int": (1, value_put(0, "connectionMachine", 7)),
            "auth allowed string": (1, value_put(1, "allowed", "true")),
            "providerVerified alias": (2, lambda r: r.__setitem__("providerVerified", r.pop("provider_verified"))),
            "provider machine_id alias": (2, lambda r: r.__setitem__("machine_id", r.pop("machineId"))),
            "provider extra key": (2, put("source", "cli")),
            "provider_verified string": (2, put("provider_verified", "ok")),
            "provider bad machine": (2, put("machineId", "vm_X-1")),
        }
        for label, (index, change) in cases.items():
            self.assertUnsupported(mutate(index, change), label)

    def test_unsupported_record_supplies_no_evidence(self) -> None:
        cli = cli_receipt()
        cli.pop("machineId")
        result = self.assertUnsupported([cli, platform_receipt(), provider()])
        self.assertEqual(result["golden_path_stages"]["chat"], "missing")

        bad_provider = {"machineId": MACHINE, "provider_verified": True, "note": "x"}
        result = self.assertUnsupported([cli_receipt(), platform_receipt(), bad_provider])
        self.assertIn("provider_proof_missing", result["blockers"])

    def test_legacy_and_foreign_records_are_unsupported(self) -> None:
        for record in (
            {"machine": MACHINE, "first_chat": {"ok": True}, "provider_verified": True},
            {"provider_verified": True},
            {"stage": "chat", "status": "ok"},
            [passing()[0]],
            "pass",
            7,
            None,
        ):
            self.assertUnsupported(passing()[:2] + [record], record)

    # Bounded parsing.

    def test_malformed_and_unreadable_input_blocks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            good = json.dumps(passing()[0])
            for text in (good + "\n{not json\n", b"\xff\xfe not utf-8"):
                code, result = write_and_run(directory, text, "--check")
                self.assertEqual(code, 2)
                self.assertEqual(result["status"], "blocked")
                self.assertEqual(result["blockers"], ["receipt_malformed"])
            self.assertEqual(write_and_run(directory, good + "\n{not json\n")[0], 0)
            self.assertEqual(receipt.main(["--receipt", str(Path(directory) / "absent.jsonl"), "--check"]), 2)

    def test_deep_nesting_blocks_without_crashing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for depth in (receipt.MAX_DEPTH + 1, 200_000):
                code, result = write_and_run(directory, "[" * depth + "]" * depth, "--check")
                self.assertEqual(code, 2)
                self.assertEqual(result["blockers"], ["receipt_malformed"])
            nested: object = {}
            for _ in range(5_000):
                nested = {"x": nested}
            records = passing()
            records[0]["stages"][3]["value"]["deep"] = nested
            self.assertNotEqual(receipt.normalize(records)["status"], "pass")

    def test_oversized_input_blocks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            line = json.dumps({"machineId": MACHINE, "provider_verified": True, "pad": "x" * receipt.MAX_LINE_BYTES})
            code, result = write_and_run(directory, line + "\n", "--check")
            self.assertEqual(code, 2)
            self.assertEqual(result["blockers"], ["receipt_malformed"])
            many = (json.dumps(provider()) + "\n") * (receipt.MAX_FILE_BYTES // 40)
            code, result = write_and_run(directory, many, "--check")
            self.assertEqual(result["blockers"], ["receipt_malformed"])

    def test_jsonl_and_json_array_inputs_and_check_exit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            jsonl = "\n".join(json.dumps(record) for record in passing()) + "\n"
            self.assertEqual(write_and_run(directory, jsonl, "--check")[0], 0)
            self.assertEqual(write_and_run(directory, json.dumps(passing()), "--check")[0], 0)
            self.assertEqual(write_and_run(directory, json.dumps(cli_receipt()), "--check")[0], 2)

    # Echo nothing: only allowlisted values reach the output.

    def test_secret_shaped_input_never_appears_in_output(self) -> None:
        rng = random.Random(37177)
        alphabet = string.ascii_letters + string.digits

        def token(prefix: str = "") -> str:
            return prefix + "".join(rng.choice(alphabet) for _ in range(32))

        secrets = [
            token("ghp_"), token("github_pat_"), token("sk-ant-"), token("sk_live_"), token("xoxb-"),
            "AKIA" + "".join(rng.choice(string.ascii_uppercase + string.digits) for _ in range(16)),
            "AWS_SECRET_ACCESS_KEY=prefix," + token("LEAK"),
            "Bearer " + token(), token("eyJ") + "." + token() + "." + token(), token(), token("vm_"),
        ]
        picks = iter(secrets * 4)
        records = passing()
        cli, platform = records[0], records[1]
        cli["probeId"] = next(picks)
        for item in cli["stages"] + platform["stages"]:
            item["requestId"] = next(picks)
            item["value"]["note"] = next(picks)
        cli["stages"][3]["value"]["session_id"] = next(picks)  # ignored: the writer never writes a raw id
        cli["stages"][2]["value"]["state"] = next(picks)
        failed = golden_receipt(next(picks), [
            stage("auth", 11, 30, ok=False, failure={
                "code": next(picks), "message": " ".join(secrets), "retryable": False,
                "details": {next(picks): next(picks), "nested": secrets},
            }),
        ])
        failed["failure"]["message"] = " ".join(secrets)
        foreign = {secret: secret for secret in secrets}
        result = receipt.normalize(records + [failed, foreign, " ".join(secrets)])
        rendered = json.dumps(result)

        self.assertNotEqual(result["status"], "pass")
        for secret in secrets:
            for fragment in {secret, secret[-20:], secret.split(",")[-1]}:
                self.assertNotIn(fragment, rendered, secret)
        self.assertIsNone(result["failures"][0]["code"])

    def test_output_strings_are_allowlisted(self) -> None:
        result = receipt.normalize(passing() + [{"x": "y"}])
        allowed_words = set(ALL_STAGES) | {
            "pass", "fail", "blocked", "ok", "failed", "missing", "not_observable", receipt.SCHEMA, MACHINE,
            CLI_PROBE, PLATFORM_PROBE,
        }

        def strings(value: object):
            if isinstance(value, str):
                yield value
            elif isinstance(value, dict):
                for key, child in value.items():
                    yield key
                    yield from strings(child)
            elif isinstance(value, list):
                for child in value:
                    yield from strings(child)

        for text in strings(result):
            self.assertRegex(text, r"^(?:[a-z_]+|cmux\.cloud-golden-path-receipt/v1|vm_[0-9a-z]+|[0-9a-f-]{36})$")
            if text not in allowed_words:
                self.assertRegex(text, r"^[a-z_]+$")

    # The join with the real CLI row (#7402).

    def cli_from_writer(self) -> dict[str, object]:
        return json.loads(CLI_FIXTURE.read_text(encoding="utf-8"))

    def platform_for(self, machine: str) -> dict[str, object]:
        return golden_receipt(PLATFORM_PROBE, [
            stage("lease", 10, 40, probe=PLATFORM_PROBE,
                  value={"machineId": machine, "connectionMachine": machine, "generation": 7}),
            stage("auth", 11, 30, probe=PLATFORM_PROBE, value={"allowed": True}),
        ], machine=machine)

    def test_writer_fixture_is_what_the_writer_writes(self) -> None:
        self.assertEqual(writer_receipt(load_writer(self)), self.cli_from_writer())

    def test_cli_writer_receipt_alone_never_passes(self) -> None:
        result = receipt.normalize([self.cli_from_writer(), provider()])

        self.assertEqual(result["status"], "blocked")
        self.assertNotIn("receipt_shape_unsupported", result["blockers"])
        self.assertEqual(result["golden_path_stages"]["lease"], "not_observable")
        self.assertEqual(result["golden_path_stages"]["auth"], "not_observable")
        self.assertIn("stage_not_observable_lease", result["blockers"])
        self.assertTrue(result["checks"]["acpmux_session_discovery"])
        self.assertTrue(result["checks"]["pause_resume_reconnect"])

    def test_cli_writer_receipt_plus_platform_and_provider_passes(self) -> None:
        result = receipt.normalize([self.cli_from_writer(), self.platform_for(MACHINE), provider()])

        self.assertEqual(result["status"], "pass", result["blockers"])
        self.assertEqual(result["golden_path_stages"], {name: "ok" for name in ALL_STAGES})
        self.assertEqual(result["stage_ms"]["chat"], 1000)
        self.assertEqual(result["stage_ms"]["lease"], 40)

    def test_cli_writer_receipt_plus_platform_for_another_machine_blocks(self) -> None:
        result = receipt.normalize([self.cli_from_writer(), self.platform_for(OTHER_MACHINE), provider()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("machine_id_mismatch", result["blockers"])

    def test_not_observable_stage_is_not_cleared_by_its_own_receipt(self) -> None:
        cli = self.cli_from_writer()
        cli["stages"].append(stage("lease", 40, 5, value={"machineId": MACHINE}))
        cli["stages"].append(stage("auth", 41, 5, value={"allowed": True}))
        result = receipt.normalize([cli, provider()])

        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["golden_path_stages"]["lease"], "not_observable")

    def test_a_non_gap_failure_beside_gaps_makes_the_receipt_prove_nothing(self) -> None:
        cli = self.cli_from_writer()
        cli["stages"][3] = {**cli["stages"][3], "ok": False}
        cli["stages"][3].pop("value")
        cli["stages"][3]["failure"] = failure("folder.mismatch")
        result = receipt.normalize([cli, self.platform_for(MACHINE), provider()])

        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["golden_path_stages"]["folder"], "failed")
        self.assertEqual(result["golden_path_stages"]["chat"], "missing")

    def cli_with_no_folder_route(self) -> dict[str, object]:
        cli = self.cli_from_writer()
        folder = next(item for item in cli["stages"] if item["stage"] == "folder")
        folder["ok"] = False
        folder.pop("value")
        folder["failure"] = {**failure("folder.no_route", "no --from-folder"), "details": {"ms": 1000}}
        return cli

    def test_no_route_is_a_gap_that_blocks_on_its_stage(self) -> None:
        result = receipt.normalize([self.cli_with_no_folder_route(), self.platform_for(MACHINE), provider()])

        self.assertEqual(result["status"], "blocked")
        self.assertNotIn("receipt_reports_failure", result["blockers"])
        self.assertIn("stage_no_route_folder", result["blockers"])
        self.assertEqual(result["golden_path_stages"]["folder"], "no_route")
        self.assertEqual(
            {name: state for name, state in result["golden_path_stages"].items() if name != "folder"},
            {name: "ok" for name in ALL_STAGES if name != "folder"},
        )
        self.assertTrue(result["checks"]["acpmux_session_discovery"])
        self.assertTrue(result["checks"]["pause_resume_reconnect"])

    def test_no_route_stage_is_cleared_only_by_another_receipt(self) -> None:
        platform = self.platform_for(MACHINE)
        platform["stages"].append(stage("folder", 12, 8, probe=PLATFORM_PROBE, value={"workspace": "golden-path"}))
        result = receipt.normalize([self.cli_with_no_folder_route(), platform, provider()])
        self.assertEqual(result["status"], "pass", result["blockers"])

        cli = self.cli_with_no_folder_route()
        cli["stages"].append(stage("folder", 40, 5, value={"workspace": "golden-path"}))
        result = receipt.normalize([cli, self.platform_for(MACHINE), provider()])
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["golden_path_stages"]["folder"], "no_route")

    def test_slug_probe_ids_are_echoed(self) -> None:
        result = receipt.normalize([self.cli_from_writer(), self.platform_for(MACHINE), provider()])
        self.assertEqual(result["probe_ids"], ["start-matrix-golden-path", PLATFORM_PROBE])
        for good in ("golden-path-nightly-7", "start-matrix-" + "a" * 51):
            cli = self.cli_from_writer()
            cli["probeId"] = good
            result = receipt.normalize([cli, self.platform_for(MACHINE), provider()])
            self.assertEqual(result["probe_ids"], [good, PLATFORM_PROBE], good)

        for bad in ("Start-matrix", "-leading-dash", "a" * 65, "has space", "under_score", "sk-ant-Abc",
                    "sk-ant-abc123", "ghp-abc123def456", "ghp-like", "plain-slug", "start-matrix",
                    "golden-path", "start-matrix-" + "a" * 52, "xstart-matrix-golden-path"):
            cli = self.cli_from_writer()
            cli["probeId"] = bad
            result = receipt.normalize([cli, self.platform_for(MACHINE), provider()])
            self.assertEqual(result["probe_ids"], [PLATFORM_PROBE], bad)

    # Review BLOCK at aabd5bf1: a gap code must name its own stage.

    def test_stage_gap_code_for_another_stage_is_a_real_failure(self) -> None:
        for code in ("auth.not_observable", "lease.no_route", "not_observable", ".not_observable"):
            cli = self.cli_from_writer()
            machine = cli["stages"][0]
            machine["ok"] = False
            machine.pop("value")
            machine["failure"] = failure(code)
            platform = self.platform_for(MACHINE)
            platform["stages"].append(stage("machine", 12, 9, probe=PLATFORM_PROBE, value={"machineId": MACHINE}))
            result = receipt.normalize([cli, platform, provider()])

            self.assertEqual(result["status"], "fail", code)
            self.assertIn("receipt_reports_failure", result["blockers"], code)
            self.assertEqual(result["golden_path_stages"]["machine"], "failed", code)
            self.assertEqual(result["golden_path_stages"]["chat"], "missing", code)

    def test_receipt_gap_code_without_its_matching_stage_failure_is_a_real_failure(self) -> None:
        cases = {
            # The code's stage passed in this receipt.
            "ok stage": {"stage": "chat", "code": "chat.not_observable"},
            # The code's stage is not in this receipt at all.
            "absent stage": {"stage": "machine", "code": "machine.not_observable"},
            # The code's stage failed, but with a different gap.
            "other gap": {"stage": "lease", "code": "lease.no_route"},
            # The code names one stage, the `stage` field another.
            "stage field mismatch": {"stage": "auth", "code": "lease.not_observable"},
        }
        for label, mismatch in cases.items():
            cli = self.cli_from_writer()
            if label == "absent stage":
                cli["stages"] = [item for item in cli["stages"] if item["stage"] != "machine"]
            cli["failure"] = {**failure(mismatch["code"]), "stage": mismatch["stage"]}
            platform = self.platform_for(MACHINE)
            platform["stages"].append(stage("machine", 12, 9, probe=PLATFORM_PROBE, value={"machineId": MACHINE}))
            platform["stages"].append(stage("chat", 13, 9, probe=PLATFORM_PROBE,
                                            value={"session_id": "sess_acp_1", "session_discovered": True}))
            result = receipt.normalize([cli, platform, provider()])

            self.assertNotEqual(result["status"], "pass", label)
            self.assertIn("receipt_reports_failure", result["blockers"], label)
            self.assertEqual(result["golden_path_stages"]["reconnect"], "missing", label)

    def test_matching_receipt_gap_still_joins(self) -> None:
        result = receipt.normalize([self.cli_from_writer(), self.platform_for(MACHINE), provider()])

        self.assertEqual(result["status"], "pass", result["blockers"])

    # The platform receipt cmux-platform#927's runner writes, and its join with the CLI row's.

    def platform_from_runner(self) -> dict[str, object]:
        return json.loads(PLATFORM_FIXTURE.read_text(encoding="utf-8"))

    def test_runner_receipt_joins_the_writer_receipt_to_pass(self) -> None:
        result = receipt.normalize([self.cli_from_writer(), self.platform_from_runner(), provider()])

        self.assertEqual(result["status"], "pass", result["blockers"])
        # reconnect is the runner's gap, cleared by the CLI receipt; lease and auth are the CLI's, cleared by it.
        self.assertEqual(result["golden_path_stages"], {name: "ok" for name in ALL_STAGES})
        self.assertTrue(result["checks"]["pause_resume_reconnect"])
        self.assertEqual(result["probe_ids"], ["start-matrix-golden-path", "3f2b8c1e-5d4a-4e6f-9a7b-1c2d3e4f5a6b"])
        self.assertEqual(result["stage_ms"]["lease"], 212)
        self.assertEqual(result["stage_ms"]["auth"], 88)

    def test_runner_receipt_alone_is_blocked(self) -> None:
        result = receipt.normalize([self.platform_from_runner(), provider()])

        self.assertEqual(result["status"], "blocked")
        self.assertNotIn("receipt_shape_unsupported", result["blockers"])
        self.assertIn("missing_acpmux_session_discovery", result["blockers"])
        self.assertIn("missing_pause_resume_reconnect", result["blockers"])
        self.assertIn("stage_not_observable_reconnect", result["blockers"])
        self.assertNotIn("receipt_reports_failure", result["blockers"])

    def test_runner_fixture_matches_the_runner_at_d32eddc0(self) -> None:
        platform = self.platform_from_runner()
        reconnect = platform["stages"][-1]
        self.assertEqual([item["stage"] for item in platform["stages"]], list(ALL_STAGES))
        self.assertEqual((reconnect["ok"], reconnect["failure"]["code"]), (False, "reconnect.not_observable"))
        self.assertNotIn("value", reconnect)
        self.assertEqual(platform["failure"], {**reconnect["failure"], "stage": "reconnect"})
        self.assertEqual(platform["outcome"], "failed")

    def test_runner_lease_and_auth_evidence_is_required(self) -> None:
        def with_value(position: int, value: dict[str, object]) -> list[object]:
            platform = self.platform_from_runner()
            platform["stages"][position]["value"] = value
            return [self.cli_from_writer(), platform, provider()]

        # Missing evidence: the stage proves nothing, so the CLI's gap stays open.
        for position, value in ((3, {"connectionMachine": MACHINE, "generation": 0}),
                                (3, {"machineId": MACHINE, "generation": 0}),
                                (3, {"machineId": MACHINE, "connectionMachine": MACHINE}),
                                (4, {})):
            result = receipt.normalize(with_value(position, value))
            self.assertEqual(result["status"], "blocked", value)
            self.assertEqual(result["golden_path_stages"][("lease", "auth")[position - 3]], "not_observable", value)
        # Negative evidence fails.
        for position, value in ((3, {"machineId": OTHER_MACHINE, "connectionMachine": MACHINE, "generation": 0}),
                                (4, {"allowed": False})):
            result = receipt.normalize(with_value(position, value))
            self.assertEqual(result["status"], "fail", value)
            self.assertIn("receipt_reports_failure", result["blockers"], value)

    def test_lease_for_another_machine_than_its_receipt_fails(self) -> None:
        platform = platform_receipt()
        platform["stages"][0]["value"]["machineId"] = OTHER_MACHINE
        result = receipt.normalize([cli_receipt(), platform, provider()])

        self.assertEqual(result["status"], "fail")
        self.assertIn("receipt_reports_failure", result["blockers"])

    # Review BLOCK at 1a18d111.

    def test_out_of_range_numbers_are_unsupported_never_a_crash(self) -> None:
        cases = {
            "int beyond float range": 10 ** 400,
            "int beyond 2**53": 2 ** 53 + 1,
            "negative int beyond 2**53": -(2 ** 53) - 1,
            "inf": float("inf"),
            "nan": float("nan"),
            "negative duration": -1,
        }
        for label, number in cases.items():
            for position, key in ((3, "reply_ms"), (3, "ms")):
                records = passing()
                records[0]["stages"][position]["value"][key] = number
                self.assertUnsupported(records, (label, key))
            records = passing()
            records[0]["stages"][4]["value"]["link"]["back_ms"] = number
            self.assertUnsupported(records, (label, "back_ms"))
            records = passing()
            records[1]["stages"][0]["value"]["generation"] = number
            self.assertUnsupported(records, (label, "generation"))
        records = passing()
        records[0]["stages"][3]["value"]["session_id_chars"] = 10 ** 400
        self.assertUnsupported(records, "session_id_chars")
        records = passing()
        records[0]["stages"][3]["value"]["reply_ms"] = 2 ** 53
        self.assertEqual(receipt.normalize(records)["status"], "pass")

    def test_huge_numbers_in_a_file_block_never_crash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for literal in ("1" * 400, "1" * 5000, "1e999", "-1e999"):
                records = passing()
                records[0]["stages"][3]["value"]["reply_ms"] = "@@N@@"
                text = "\n".join(json.dumps(record) for record in records).replace('"@@N@@"', literal) + "\n"
                code, result = write_and_run(directory, text, "--check")
                self.assertEqual(code, 2, literal)
                self.assertEqual(result["status"], "blocked", literal)
                self.assertTrue({"receipt_shape_unsupported", "receipt_malformed"} & set(result["blockers"]), literal)

    def test_ok_gap_stage_joined_with_a_clean_receipt_never_passes(self) -> None:
        cli = self.cli_from_writer()
        for item in cli["stages"]:
            if item["stage"] in ("lease", "auth"):
                item["ok"] = True
                item["value"] = ({"machineId": MACHINE, "connectionMachine": MACHINE, "generation": 0}
                                 if item["stage"] == "lease" else {"allowed": True})
        self.assertIn("failure", cli["stages"][2])
        result = self.assertUnsupported([cli, self.platform_from_runner(), provider()])
        # The CLI receipt supplies nothing: no discovery evidence, and the runner's reconnect gap stays open.
        self.assertFalse(result["checks"]["acpmux_session_discovery"])
        self.assertEqual(result["golden_path_stages"]["reconnect"], "not_observable")

    # Review BLOCK at 8ba8aa2a: every evidence path is required, not only the ones a check happened to name.

    REQUIRED_EVIDENCE = {
        "chat": {("session_id_chars",): 0, ("session_id_sha256",): "", ("session_discovered",): False},
        "reconnect": {
            ("pause", "state"): "running",
            ("resume", "state"): "paused",
            ("link", "dropped_while_paused"): False,
            ("link", "back"): False,
            ("second_reply", "ok"): False,
            ("reconnected",): False,
        },
    }

    def joined_with(self, stage_name: str, change) -> dict[str, object]:
        cli = self.cli_from_writer()
        value = next(item for item in cli["stages"] if item["stage"] == stage_name)["value"]
        change(value)
        return receipt.normalize([cli, self.platform_from_runner(), provider()])

    def test_writer_fixture_with_every_required_path_passes(self) -> None:
        self.assertEqual(receipt.normalize([self.cli_from_writer(), self.platform_from_runner(), provider()])["status"],
                         "pass")

    def test_deleting_any_required_evidence_path_never_passes(self) -> None:
        for stage_name, paths in self.REQUIRED_EVIDENCE.items():
            for path in paths:
                with self.subTest(stage=stage_name, path=".".join(path)):
                    def delete(value, path=path):
                        for key in path[:-1]:
                            value = value[key]
                        del value[path[-1]]
                    result = self.joined_with(stage_name, delete)
                    self.assertNotEqual(result["status"], "pass")
                    check = "acpmux_session_discovery" if stage_name == "chat" else "pause_resume_reconnect"
                    self.assertFalse(result["checks"][check])
            for parent in {path[0] for path in paths if len(path) > 1}:
                with self.subTest(stage=stage_name, path=parent):
                    result = self.joined_with(stage_name, lambda value, parent=parent: value.pop(parent))
                    self.assertNotEqual(result["status"], "pass")

    def test_a_wrong_required_evidence_value_never_passes(self) -> None:
        for stage_name, paths in self.REQUIRED_EVIDENCE.items():
            for path, wrong in paths.items():
                with self.subTest(stage=stage_name, path=".".join(path), value=wrong):
                    def put(value, path=path, wrong=wrong):
                        for key in path[:-1]:
                            value = value[key]
                        value[path[-1]] = wrong
                    self.assertNotEqual(self.joined_with(stage_name, put)["status"], "pass")


if __name__ == "__main__":
    unittest.main()
