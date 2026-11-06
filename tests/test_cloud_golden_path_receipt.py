#!/usr/bin/env python3
"""Focused tests for the Cloud golden-path receipt validator."""
from __future__ import annotations

import copy
import importlib.util
import json
import random
import string
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "cmux-next" / "cloud_golden_path_receipt.py"
SPEC = importlib.util.spec_from_file_location("cloud_golden_path_receipt", MODULE_PATH)
assert SPEC and SPEC.loader
receipt = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipt)

MACHINE = "vm_ab12cd34ef56ab12cd34"
OTHER_MACHINE = "vm_ffff0000ffff0000ffff"
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
    chat_value = {"events": 2, "final": "done", "session_id": "sess_acp_1", "session_discovered": True}
    chat_value.update(chat or {})
    reconnect_value = {"events": 3, "final": "done", "paused": True, "resumed": True, "reconnected": True}
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

    def test_ok_stage_with_failure_object_fails(self) -> None:
        platform = platform_receipt()
        platform["stages"][1]["failure"] = failure("auth.denied")
        result = receipt.normalize([cli_receipt(), platform, provider()])

        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["golden_path_stages"]["auth"], "failed")

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

        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["golden_path_stages"]["lease"], "missing")
        self.assertEqual(result["golden_path_stages"]["auth"], "not_observable")

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
        result = receipt.normalize([cli_receipt(), other, provider()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("machine_id_mismatch", result["blockers"])

    def test_discovery_evidence(self) -> None:
        result = receipt.normalize([cli_receipt(chat={"session_discovered": None}), platform_receipt(), provider()])
        self.assertEqual(result["status"], "blocked")
        self.assertIn("missing_acpmux_session_discovery", result["blockers"])

        result = receipt.normalize([cli_receipt(chat={"session_id": None}), platform_receipt(), provider()])
        self.assertEqual(result["status"], "blocked")

        result = receipt.normalize([cli_receipt(chat={"session_discovered": False}), platform_receipt(), provider()])
        self.assertEqual(result["status"], "fail")
        self.assertIn("receipt_reports_failure", result["blockers"])

    def test_continuity_evidence(self) -> None:
        for key in ("paused", "resumed", "reconnected"):
            result = receipt.normalize([cli_receipt(reconnect={key: None}), platform_receipt(), provider()])
            self.assertEqual(result["status"], "blocked", key)
            self.assertIn("missing_pause_resume_reconnect", result["blockers"], key)
            result = receipt.normalize([cli_receipt(reconnect={key: False}), platform_receipt(), provider()])
            self.assertEqual(result["status"], "fail", key)

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
            "non-hex machineId": (0, put("machineId", "vm_zz99zz99")),
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
            "paused string": (0, value_put(4, "paused", "ok")),
            "session_id not a string": (0, value_put(3, "session_id", 7)),
            "providerVerified alias": (2, lambda r: r.__setitem__("providerVerified", r.pop("provider_verified"))),
            "provider machine_id alias": (2, lambda r: r.__setitem__("machine_id", r.pop("machineId"))),
            "provider extra key": (2, put("source", "cli")),
            "provider_verified string": (2, put("provider_verified", "ok")),
            "provider non-hex machine": (2, put("machineId", "vm_xyz")),
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
        cli["stages"][3]["value"]["session_id"] = next(picks)
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
            self.assertRegex(text, r"^(?:[a-z_]+|cmux\.cloud-golden-path-receipt/v1|vm_[0-9a-f]+|[0-9a-f-]{36})$")
            if text not in allowed_words:
                self.assertRegex(text, r"^[a-z_]+$")


if __name__ == "__main__":
    unittest.main()
