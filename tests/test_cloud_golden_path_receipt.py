#!/usr/bin/env python3
"""Focused tests for the Cloud golden-path receipt adapter."""
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "cmux-next" / "cloud_golden_path_receipt.py"
SPEC = importlib.util.spec_from_file_location("cloud_golden_path_receipt", MODULE_PATH)
assert SPEC and SPEC.loader
receipt = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receipt)


def legacy_records() -> list[dict[str, object]]:
    """#37147's ad-hoc shape, which the validator no longer reads."""
    return [
        {
            "request_id": "req-golden-1",
            "probe": "cloud-chat-replies-production",
            "outcome": "ok",
            "machine_id": "vm_ab12",
            "session_id": "sess_acp_1",
            "steps": [
                {"step": "cloud start-chat", "exit": 0, "reply": "ok"},
                {"step": "ACP session discovered", "status": "ok"},
            ],
        },
        {
            "continuity": {
                "pause_landed": True,
                "resume_reached_running": True,
                "reconnected": True,
            },
            "provider_verified": True,
        },
    ]


MACHINE = "vm_ab12cd34ef56gh78ij90"


def stage(name: str, second: int, ms: int, *, probe: str = "cli-1", ok: bool = True,
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


def golden_receipt(probe: str, stages: list[dict[str, object]], machine: str | None = MACHINE) -> dict[str, object]:
    failed = next((s for s in stages if not s["ok"]), None)
    receipt_value: dict[str, object] = {
        "version": 1,
        "probeId": probe,
        "startedAt": "2026-11-06T18:00:00.000Z",
        "endedAt": "2026-11-06T18:00:59.000Z",
        "outcome": "failed" if failed else "passed",
        "stages": stages,
    }
    if machine:
        receipt_value["machineId"] = machine
    if failed:
        receipt_value["failure"] = {**failed["failure"], "stage": failed["stage"]}
    return receipt_value


def cli_receipt(**chat_value: object) -> dict[str, object]:
    chat = {
        "session_id": "sess_acp_1",
        "discovery": {"source": "acpmux sessions list", "found": True},
        "provider_verified": True,
        "reply": "ok",
    }
    chat.update(chat_value)
    chat = {key: value for key, value in chat.items() if value is not None}
    return golden_receipt("cli-1", [
        stage("machine", 1, 120, value={"machineId": MACHINE, "workspace": "golden-path", "created": True}),
        stage("folder", 2, 5, value={"workspace": "golden-path", "folder": "$HOME"}),
        stage("readiness", 3, 900, value={"state": "running", "tunnel": "up", "guest_identity": MACHINE,
                                          "exec_request_id": "exec-1"}),
        stage("chat", 5, 450, value=chat),
        stage("reconnect", 7, 800, value={"pause": {"state": "paused"}, "resume": {"state": "running"},
                                          "reconnected": True, "reply": "ok"}),
    ])


def platform_receipt(**auth: object) -> dict[str, object]:
    auth_stage = stage("auth", 11, 30, probe="plat-1", value={"allowed": True})
    auth_stage.update(auth)
    return golden_receipt("plat-1", [
        stage("lease", 10, 40, probe="plat-1",
              value={"machineId": MACHINE, "connectionMachine": MACHINE, "generation": 7}),
        auth_stage,
    ])


class GoldenPathReceiptTests(unittest.TestCase):
    def test_golden_path_receipts_merge_to_pass_with_stage_ms(self) -> None:
        result = receipt.normalize([cli_receipt(), platform_receipt()])

        self.assertEqual(result["status"], "pass", result["blockers"])
        self.assertEqual(result["blockers"], [])
        self.assertEqual(result["machine_id"], MACHINE)
        self.assertEqual(result["session_id"], "sess_acp_1")
        self.assertTrue(all(result["stages"].values()))
        self.assertEqual(
            result["golden_path_stages"],
            {name: "ok" for name in ("machine", "folder", "readiness", "lease", "auth", "chat", "reconnect")},
        )
        self.assertEqual(
            result["stage_ms"],
            {"machine": 120, "folder": 5, "readiness": 900, "lease": 40, "auth": 30, "chat": 450, "reconnect": 800},
        )

    def test_golden_path_missing_lease_and_auth_blocks(self) -> None:
        result = receipt.normalize([cli_receipt()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("missing_stage_lease", result["blockers"])
        self.assertIn("missing_stage_auth", result["blockers"])
        self.assertEqual(result["golden_path_stages"]["lease"], "missing")

    def test_golden_path_failed_stage_fails(self) -> None:
        denied = platform_receipt(
            ok=False,
            value=None,
            failure={"code": "auth.denied", "message": "no chat grant", "retryable": False},
        )
        denied["stages"][1].pop("value")
        result = receipt.normalize([cli_receipt(), denied])

        self.assertEqual(result["status"], "fail")
        self.assertIn("receipt_reports_failure", result["blockers"])
        self.assertIn("stage_failed_auth", result["blockers"])
        self.assertEqual(result["golden_path_stages"]["auth"], "failed")
        self.assertEqual(result["failures"][0]["code"], "auth.denied")

    def test_golden_path_failure_in_one_receipt_beats_ok_in_another(self) -> None:
        cli = cli_receipt()
        failed_chat = golden_receipt("plat-1", [
            stage("lease", 10, 40, probe="plat-1", value={"machineId": MACHINE}),
            stage("auth", 11, 30, probe="plat-1", value={"allowed": True}),
            stage("chat", 12, 70, probe="plat-1", ok=False,
                  failure={"code": "chat.error", "message": "the machine returned a chat error", "retryable": False}),
        ])
        result = receipt.normalize([cli, failed_chat])

        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["golden_path_stages"]["chat"], "failed")

    def test_golden_path_not_observable_blocks(self) -> None:
        cli = cli_receipt()
        cli["stages"][2] = stage("readiness", 3, 900, ok=False, failure={
            "code": "readiness.not_observable", "message": "no tunnel probe in this build", "retryable": False,
        })
        cli["outcome"] = "failed"
        cli["failure"] = {**cli["stages"][2]["failure"], "stage": "readiness"}
        result = receipt.normalize([cli, platform_receipt()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("stage_not_observable_readiness", result["blockers"])
        self.assertNotIn("receipt_reports_failure", result["blockers"])
        self.assertEqual(result["golden_path_stages"]["readiness"], "not_observable")

    def test_golden_path_without_provider_proof_is_blocked(self) -> None:
        result = receipt.normalize([cli_receipt(provider_verified=None), platform_receipt()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("provider_proof_missing", result["blockers"])

    def test_golden_path_rejected_provider_proof_fails(self) -> None:
        result = receipt.normalize([cli_receipt(provider_verified=False), platform_receipt()])

        self.assertEqual(result["status"], "fail")
        self.assertIn("provider_proof_rejected", result["blockers"])

    def test_golden_path_chat_without_session_discovery_is_blocked(self) -> None:
        result = receipt.normalize([cli_receipt(discovery=None), platform_receipt()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("missing_acpmux_session_discovery", result["blockers"])

    def test_golden_path_reconnect_without_pause_resume_is_blocked(self) -> None:
        cli = cli_receipt()
        cli["stages"][4]["value"] = {"events": 3, "final": "done", "reconnected": True}
        result = receipt.normalize([cli, platform_receipt()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("missing_pause_resume_reconnect", result["blockers"])

    def test_golden_path_receipts_for_different_machines_do_not_merge(self) -> None:
        other = platform_receipt()
        other["machineId"] = "vm_zz99zz99zz99zz99zz99"
        result = receipt.normalize([cli_receipt(), other])

        self.assertNotEqual(result["status"], "pass")
        self.assertIn("machine_id_mismatch", result["blockers"])

    def test_golden_path_failed_outcome_without_failed_stage_fails(self) -> None:
        cli = cli_receipt()
        cli["outcome"] = "failed"
        result = receipt.normalize([cli, platform_receipt()])

        self.assertEqual(result["status"], "fail")

    def test_golden_path_jsonl_receipts_and_check_exit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "golden-path.jsonl"
            path.write_text(
                "\n".join(json.dumps(r) for r in (cli_receipt(), platform_receipt())) + "\n", encoding="utf-8"
            )
            self.assertEqual(receipt.main(["--receipt", str(path), "--check"]), 0)
            path.write_text(json.dumps(cli_receipt()), encoding="utf-8")
            self.assertEqual(receipt.main(["--receipt", str(path), "--check"]), 2)

    def test_golden_path_negative_value_evidence_fails(self) -> None:
        for chat_value, reconnect_value in (
            ({"discovery": {"source": "acpmux sessions list", "found": False}}, None),
            (None, {"pause": {"state": "running"}, "resume": {"state": "running"}, "reconnected": True}),
            (None, {"pause": {"state": "paused"}, "resume": {"state": "paused"}, "reconnected": True}),
        ):
            cli = cli_receipt(**(chat_value or {}))
            if reconnect_value:
                cli["stages"][4]["value"] = reconnect_value
            result = receipt.normalize([cli, platform_receipt()])
            self.assertEqual(result["status"], "fail", (chat_value, reconnect_value))
            self.assertIn("receipt_reports_failure", result["blockers"])

    def test_golden_path_discovery_without_positive_evidence_is_blocked(self) -> None:
        result = receipt.normalize([cli_receipt(discovery={"source": "acpmux sessions list"}), platform_receipt()])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("missing_acpmux_session_discovery", result["blockers"])

    # Review BLOCK at 78ff0902 (#37177).

    def test_malformed_jsonl_returns_blocked_result(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "golden-path.jsonl"
            path.write_text(json.dumps(cli_receipt()) + "\n{not json\n", encoding="utf-8")
            output = Path(directory) / "normalized.json"
            self.assertEqual(receipt.main(["--receipt", str(path), "--out", str(output), "--check"]), 2)
            result = json.loads(output.read_text())
            self.assertEqual(result["status"], "blocked")
            self.assertIn("receipt_malformed", result["blockers"])
            self.assertEqual(receipt.main(["--receipt", str(path), "--out", str(output)]), 0)
            path.write_bytes(b"\xff\xfe not utf-8")
            self.assertEqual(receipt.main(["--receipt", str(path), "--out", str(output), "--check"]), 2)
            self.assertEqual(json.loads(output.read_text())["status"], "blocked")
            self.assertEqual(receipt.main(["--receipt", str(Path(directory) / "absent.jsonl"), "--check"]), 2)

    def test_only_exact_true_ok_or_passed_count_as_success(self) -> None:
        for word in ("running", "ready", "success", "succeeded", "pass", "yes", 1):
            result = receipt.normalize([cli_receipt(provider_verified=word), platform_receipt()])
            self.assertNotEqual(result["status"], "pass", word)
            self.assertIn("provider_proof_missing", result["blockers"], word)
        for word in (True, "ok", "passed"):
            result = receipt.normalize([cli_receipt(provider_verified=word), platform_receipt()])
            self.assertEqual(result["status"], "pass", (word, result["blockers"]))
        result = receipt.normalize([cli_receipt(discovery={"found": "running"}), platform_receipt()])
        self.assertNotEqual(result["status"], "pass")
        self.assertFalse(result["stages"]["acpmux_session_discovery"])

    def test_golden_stage_ok_true_with_failure_object_fails(self) -> None:
        platform = platform_receipt()
        platform["stages"][1]["failure"] = {"code": "auth.denied", "message": "no chat grant", "retryable": False}
        result = receipt.normalize([cli_receipt(), platform])

        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["golden_path_stages"]["auth"], "failed")
        self.assertIn("stage_failed_auth", result["blockers"])

    def test_provider_proof_for_another_machine_does_not_count(self) -> None:
        other = "vm_zz99zz99zz99zz99zz99"
        result = receipt.normalize([
            cli_receipt(provider_verified=None),
            platform_receipt(),
            {"machineId": other, "provider_verified": True},
        ])
        self.assertEqual(result["status"], "blocked")
        self.assertIn("provider_proof_missing", result["blockers"])

        result = receipt.normalize([
            cli_receipt(provider_verified=None), platform_receipt(), {"provider_verified": True},
        ])
        self.assertEqual(result["status"], "blocked")
        self.assertIn("provider_proof_missing", result["blockers"])

        result = receipt.normalize([
            cli_receipt(provider_verified=None), platform_receipt(), {"machineId": MACHINE, "provider_verified": True},
        ])
        self.assertEqual(result["status"], "pass", result["blockers"])

        result = receipt.normalize([
            cli_receipt(provider={"machineId": other, "provider_verified": True}, provider_verified=None),
            platform_receipt(),
        ])
        self.assertEqual(result["status"], "blocked")
        self.assertIn("provider_proof_missing", result["blockers"])

    def test_discovery_for_another_machine_does_not_count(self) -> None:
        other = "vm_zz99zz99zz99zz99zz99"
        result = receipt.normalize([
            cli_receipt(discovery={"source": "acpmux sessions list", "found": True, "machineId": other}),
            platform_receipt(),
        ])
        self.assertEqual(result["status"], "blocked")
        self.assertIn("missing_acpmux_session_discovery", result["blockers"])

    def test_receipt_without_machine_id_cannot_supply_evidence(self) -> None:
        unbound_chat = golden_receipt("cli-2", [
            stage("chat", 5, 450, probe="cli-2", value={
                "session_id": "sess_acp_1",
                "discovery": {"found": True},
                "provider_verified": True,
            }),
        ], machine=None)
        cli = cli_receipt(discovery=None, provider_verified=None)
        result = receipt.normalize([cli, platform_receipt(), unbound_chat])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("provider_proof_missing", result["blockers"])
        self.assertIn("missing_acpmux_session_discovery", result["blockers"])
        self.assertIn("receipt_machine_id_missing", result["blockers"])

    def test_credentials_are_redacted_from_output(self) -> None:
        secrets = [
            "ghp_" + "A1b2" * 9,
            "gho_" + "Z9y8" * 9,
            "github_pat_11ABCDEFG0" + "x" * 40,
            "sk-" + "proj" + "Q" * 30,
            "sk-ant-api03-" + "k" * 30,
            "sk_live_" + "4eC39HqLyjWDarjtT1zdp7dc",
            "xoxb-123456789012-123456789012-" + "a" * 24,
            "xoxp-123456789012-123456789012-" + "b" * 24,
            "AKIA" + "IOSFODNN7EXAMPLE",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "glpat-" + "x" * 20,
            "AIza" + "S" * 35,
        ]
        message = "auth said Bearer abc.def.ghi and " + " ".join(secrets)
        platform = platform_receipt(ok=False, failure={"code": "auth.denied", "message": message, "retryable": False})
        platform["probeId"] = secrets[0]
        cli = cli_receipt(session_id=secrets[5])
        result = receipt.normalize([cli, platform])
        rendered = json.dumps(result)

        self.assertEqual(result["status"], "fail")
        for secret in secrets + ["abc.def.ghi"]:
            self.assertNotIn(secret, rendered)
        self.assertIn("[withheld]", rendered)

    # Re-review BLOCK at 02f73a11 (#37177): one receipt shape only.

    def test_legacy_receipt_shape_is_unsupported(self) -> None:
        result = receipt.normalize(legacy_records())

        self.assertEqual(result["status"], "blocked")
        self.assertIn("receipt_shape_unsupported", result["blockers"])

    def test_legacy_records_beside_golden_receipts_are_never_evidence(self) -> None:
        failed_first_chat = {
            "machine": MACHINE,
            "first_chat": {"ok": False, "turn": {"session_id": "sess_acp_1"}},
            "rounds": [{"paused": True, "chat": {"reply_ok": True}, "resume": {"running": True}}],
            "provider_verified": True,
        }
        result = receipt.normalize([cli_receipt(provider_verified=None), platform_receipt(), failed_first_chat])

        self.assertEqual(result["status"], "blocked")
        self.assertIn("receipt_shape_unsupported", result["blockers"])
        self.assertIn("provider_proof_missing", result["blockers"])

    def test_legacy_provider_evidence_for_another_machine_is_unsupported(self) -> None:
        records = legacy_records()
        records[0]["machine_id"] = "vm_ffff"
        records[1]["machine_id"] = "vm_ab12"
        result = receipt.normalize(records)

        self.assertNotEqual(result["status"], "pass")
        self.assertIn("receipt_shape_unsupported", result["blockers"])

    def test_machine_bound_provider_record_is_accepted(self) -> None:
        result = receipt.normalize([
            cli_receipt(provider_verified=None), platform_receipt(), {"machineId": MACHINE, "provider_verified": True},
        ])

        self.assertEqual(result["status"], "pass", result["blockers"])
        self.assertNotIn("receipt_shape_unsupported", result["blockers"])

    def test_any_present_failure_value_fails_an_ok_stage(self) -> None:
        for failure in ({}, "", [], 0, False):
            platform = platform_receipt()
            platform["stages"][1]["failure"] = failure
            result = receipt.normalize([cli_receipt(), platform])
            self.assertEqual(result["status"], "fail", failure)
            self.assertEqual(result["golden_path_stages"]["auth"], "failed", failure)
        platform = platform_receipt()
        platform["stages"][1]["failure"] = None
        self.assertEqual(receipt.normalize([cli_receipt(), platform])["status"], "pass")

    def test_receipt_level_failure_beside_passed_outcome_fails(self) -> None:
        platform = platform_receipt()
        platform["failure"] = {}
        result = receipt.normalize([cli_receipt(), platform])

        self.assertEqual(result["status"], "fail")

    def test_credential_key_value_pairs_are_redacted(self) -> None:
        values = [
            "wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY",
            "hunter2hunter2",
            "s3cr3t-client-value",
            "plain-token-value-123",
            "abc123privatekeymaterial",
            "credential-blob-xyz",
            "authvalue987",
            "apikeyvalue654",
        ]
        message = " ".join([
            f"AWS_SECRET_ACCESS_KEY={values[0]}",
            f"db_password: {values[1]}",
            f'{{"client_secret": "{values[2]}"}}',
            f"GITHUB_TOKEN={values[3]}",
            f"PRIVATE_KEY='{values[4]}'",
            f"gcp_credentials={values[5]}",
            f"X-Auth: {values[6]}",
            f"API_KEY = {values[7]}",
        ])
        platform = platform_receipt(ok=False, failure={"code": "auth.denied", "message": message, "retryable": False})
        rendered = json.dumps(receipt.normalize([cli_receipt(), platform]))

        for value in values:
            self.assertNotIn(value, rendered)
        self.assertIn("AWS_SECRET_ACCESS_KEY", rendered)


if __name__ == "__main__":
    unittest.main()
