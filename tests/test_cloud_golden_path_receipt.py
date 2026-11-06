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


if __name__ == "__main__":
    unittest.main()
