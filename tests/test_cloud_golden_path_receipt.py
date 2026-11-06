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


ORCHESTRATOR_STAGES = (
    ("machine.create", {"machine_id": "vm_ab12", "folder": "$HOME", "route": "cloud start-chat --name"}),
    ("folder.readiness", {"machine_id": "vm_ab12", "ready": True}),
    ("lease.acquire", {"machine_id": "vm_ab12", "lease_id": "machine:vm_ab12"}),
    ("auth.exchange", {"machine_id": "vm_ab12", "signed_in": True}),
    ("chat.first_reply", {"machine_id": "vm_ab12", "first_token": "ok", "session_id": "sess_acp_1"}),
    ("session.pause", {"machine_id": "vm_ab12", "paused": True}),
    ("session.resume", {"machine_id": "vm_ab12", "resumed": True}),
    ("session.reconnect", {"machine_id": "vm_ab12", "reconnected": True}),
)


def orchestrator_record(stage: str, status: str, details: dict | None = None, failure: dict | None = None) -> dict:
    return {
        "schema_version": "golden-path/v1",
        "request_id": "nightly-golden-path",
        "mode": "production-cli",
        "proof_scope": "production-nightly",
        "stage": stage,
        "status": status,
        "occurred_at_ms": 1_000,
        "details": details or {},
        "failure": failure,
    }


def orchestrator_records() -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for stage, details in ORCHESTRATOR_STAGES:
        records.append(orchestrator_record(stage, "started"))
        records.append(orchestrator_record(stage, "ok", details))
    return records


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

    def test_orchestrator_jsonl_receipt_passes_with_provider_proof(self) -> None:
        records = orchestrator_records() + [{"provider_verified": True}]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "golden-path.jsonl"
            path.write_text("\n".join(json.dumps(record) for record in records) + "\n", encoding="utf-8")
            result = receipt.normalize(receipt.load_receipt(path))

        self.assertEqual(result["status"], "pass", result["blockers"])
        self.assertEqual(result["machine_id"], "vm_ab12")
        self.assertEqual(result["session_id"], "sess_acp_1")
        self.assertEqual(result["request_id"], "nightly-golden-path")
        self.assertTrue(all(result["stages"].values()))

    def test_orchestrator_receipt_without_provider_proof_is_blocked(self) -> None:
        result = receipt.normalize(orchestrator_records())

        self.assertEqual(result["status"], "blocked")
        self.assertIn("provider_proof_missing", result["blockers"])

    def test_orchestrator_error_record_fails_the_receipt(self) -> None:
        records = [r for r in orchestrator_records() if r["stage"] != "session.resume"]
        index = next(i for i, r in enumerate(records) if r["stage"] == "session.reconnect")
        records[index:index] = [
            orchestrator_record("session.resume", "started"),
            orchestrator_record(
                "session.resume",
                "error",
                failure={"code": "resume_failed", "stage": "session.resume", "message": "machine stayed paused"},
            ),
        ]
        records.append({"provider_verified": True})
        result = receipt.normalize(records)

        self.assertEqual(result["status"], "fail")
        self.assertIn("receipt_reports_failure", result["blockers"])
        self.assertFalse(result["stages"]["pause_resume_reconnect"])

    def test_orchestrator_error_without_status_word_still_fails(self) -> None:
        records = orchestrator_records() + [{"provider_verified": True}]
        records.append(
            {
                "stage": "chat.first_reply",
                "status": "done",
                "failure": {"code": "no_reply", "stage": "chat.first_reply", "message": "no reply"},
            }
        )
        result = receipt.normalize(records)

        self.assertEqual(result["status"], "fail")
        self.assertFalse(result["stages"]["first_reply"])

    def test_orchestrator_started_without_terminal_record_fails(self) -> None:
        records = orchestrator_records()
        last = max(i for i, r in enumerate(records) if r["stage"] == "session.reconnect")
        del records[last]
        records.append({"provider_verified": True})
        result = receipt.normalize(records)

        self.assertEqual(result["status"], "fail")
        self.assertIn("receipt_reports_failure", result["blockers"])
        self.assertIn("stage_unfinished", result["blockers"])
        self.assertFalse(result["stages"]["pause_resume_reconnect"])

    def test_orchestrator_started_only_first_reply_fails(self) -> None:
        records = [
            orchestrator_record("machine.create", "started"),
            orchestrator_record("machine.create", "ok", dict(ORCHESTRATOR_STAGES[0][1])),
            orchestrator_record("chat.first_reply", "started"),
            {"provider_verified": True},
        ]
        result = receipt.normalize(records)

        self.assertEqual(result["status"], "fail")
        self.assertFalse(result["stages"]["first_reply"])
        self.assertFalse(result["stages"]["acpmux_session_discovery"])


if __name__ == "__main__":
    unittest.main()
