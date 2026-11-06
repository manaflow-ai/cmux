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


def passing_records() -> list[dict[str, object]]:
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
    def test_normalizes_app_and_pause_resume_receipts_to_pass(self) -> None:
        result = receipt.normalize(passing_records())

        self.assertEqual(result["schema"], receipt.SCHEMA)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["machine_id"], "vm_ab12")
        self.assertEqual(result["session_id"], "sess_acp_1")
        self.assertEqual(result["blockers"], [])
        self.assertEqual(
            result["stages"],
            {
                "fresh_cloud_chat_start": True,
                "acpmux_session_discovery": True,
                "first_reply": True,
                "pause_resume_reconnect": True,
            },
        )

    def test_reply_without_provider_evidence_is_blocked(self) -> None:
        records = passing_records()
        records[1].pop("provider_verified")
        result = receipt.normalize(records)

        self.assertEqual(result["status"], "blocked")
        self.assertIn("provider_proof_missing", result["blockers"])

    def test_session_id_without_acpmux_discovery_is_blocked(self) -> None:
        records = passing_records()
        records[0]["steps"] = [{"step": "cloud start-chat", "exit": 0, "reply": "ok"}]
        result = receipt.normalize(records)

        self.assertEqual(result["status"], "blocked")
        self.assertIn("missing_acpmux_session_discovery", result["blockers"])

    def test_failed_continuity_receipt_cannot_pass(self) -> None:
        records = passing_records()
        records[1]["continuity"] = {
            "pause_landed": True,
            "resume_reached_running": False,
            "reconnected": True,
        }
        result = receipt.normalize(records)

        self.assertEqual(result["status"], "fail")
        self.assertIn("receipt_reports_failure", result["blockers"])
        self.assertIn("missing_pause_resume_reconnect", result["blockers"])

    def test_paused_resume_harness_rounds_are_consumed(self) -> None:
        records = [
            {
                "machine": "vm_ab12",
                "first_chat": {
                    "ok": True,
                    "turn": {"session_id": "sess_acp_1", "first_text_ms": 42},
                },
                "rounds": [
                    {
                        "paused": True,
                        "chat": {"reply_ok": True},
                        "resume": {"running": True},
                    },
                    {
                        "paused": True,
                        "chat": {"reply_ok": True},
                        "resume": {"running": True},
                    },
                ],
                "outcome": "ok",
                "provider_verified": True,
            }
        ]

        result = receipt.normalize(records)

        self.assertEqual(result["status"], "pass")
        self.assertTrue(result["stages"]["fresh_cloud_chat_start"])
        self.assertTrue(result["stages"]["acpmux_session_discovery"])
        self.assertTrue(result["stages"]["pause_resume_reconnect"])

    def test_jsonl_input_and_check_exit_are_supported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.jsonl"
            path.write_text(
                "\n".join(json.dumps(record) for record in passing_records()) + "\n",
                encoding="utf-8",
            )
            self.assertEqual(len(receipt.load_receipt(path)), 2)
            output = Path(directory) / "normalized.json"
            self.assertEqual(
                receipt.main(["--receipt", str(path), "--out", str(output), "--check"]),
                0,
            )
            self.assertEqual(json.loads(output.read_text())["status"], "pass")

    def test_nonzero_exit_steps_fail_the_receipt(self) -> None:
        records = passing_records()
        records[0]["steps"] = [
            {"step": "cloud start-chat", "exit": 1, "reply": "ok"},
            {"step": "ACP session discovered", "exit": 1},
        ]
        result = receipt.normalize(records)

        self.assertEqual(result["status"], "fail")
        self.assertIn("receipt_reports_failure", result["blockers"])
        self.assertFalse(result["stages"]["fresh_cloud_chat_start"])
        self.assertFalse(result["stages"]["acpmux_session_discovery"])

    def test_named_step_without_success_evidence_does_not_prove_discovery(self) -> None:
        records = passing_records()
        records[0]["steps"] = [
            {"step": "cloud start-chat", "exit": 0, "reply": "ok"},
            {"step": "ACP session discovered"},
        ]
        result = receipt.normalize(records)

        self.assertNotEqual(result["status"], "pass")
        self.assertFalse(result["stages"]["acpmux_session_discovery"])

    def test_failed_round_in_another_merged_record_fails_continuity(self) -> None:
        good_round = {"paused": True, "chat": {"reply_ok": True}, "resume": {"running": True}}
        bad_round = {"paused": True, "chat": {"reply_ok": True}, "resume": {"running": False}}
        records = [
            {
                "machine": "vm_ab12",
                "first_chat": {"ok": True, "turn": {"session_id": "sess_acp_1"}},
                "rounds": [good_round],
                "provider_verified": True,
            },
            {"machine": "vm_ab12", "rounds": [bad_round]},
        ]
        result = receipt.normalize(records)

        self.assertEqual(result["status"], "fail")
        self.assertIn("receipt_reports_failure", result["blockers"])
        self.assertFalse(result["stages"]["pause_resume_reconnect"])

    def test_failed_round_in_same_record_fails_continuity(self) -> None:
        records = [
            {
                "machine": "vm_ab12",
                "first_chat": {"ok": True, "turn": {"session_id": "sess_acp_1"}},
                "rounds": [
                    {"paused": True, "chat": {"reply_ok": True}, "resume": {"running": True}},
                    {"paused": True, "chat": {"reply_ok": False}, "resume": {"running": True}},
                ],
                "provider_verified": True,
            }
        ]
        result = receipt.normalize(records)

        self.assertEqual(result["status"], "fail")
        self.assertFalse(result["stages"]["pause_resume_reconnect"])

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


if __name__ == "__main__":
    unittest.main()
