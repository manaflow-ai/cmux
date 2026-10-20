#!/usr/bin/env python3
"""Contract tests for the shipped CMUX -> Glaeda semantic request seam."""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = os.environ.get("CMUX_CLI_BIN")
REQUEST = ROOT / "tests/fixtures/glaeda-external-request.json"
RECEIPT = ROOT / "tests/fixtures/glaeda-external-result.json"


@unittest.skipUnless(CLI, "CMUX_CLI_BIN is required")
class GlaedaExecutionCLITests(unittest.TestCase):
    maxDiff = None

    def run_cli(self, *args: str, stdin: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
        env = os.environ.copy()
        env["CMUX_SOCKET_PATH"] = "/tmp/cmux-glaeda-contract-no-socket.sock"
        return subprocess.run(
            [CLI, *args],
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            timeout=10,
            check=False,
        )

    def request_args(self) -> list[str]:
        return [
            "glaeda",
            "request",
            "--request-ref",
            "cmux:exec:1050:fixture-1",
            "--work-ref",
            "cmux:work:1050",
            "--repository",
            "teamleaderleo/glaeda",
            "--commit",
            "0409c2f4e82385d0770bb2b34f34fd3e6e2dbc36",
            "--tree",
            "03613a93ce152aefddbb246613084705043b1397",
        ]

    def test_request_is_exact_glaeda_fixture_without_socket(self) -> None:
        result = self.run_cli(*self.request_args())
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, REQUEST.read_bytes())
        self.assertEqual(result.stderr, b"")

        document = json.loads(result.stdout)
        self.assertEqual(document["operation"], "verify_focused")
        self.assertEqual(document["requested_capability_class"], "credentialless_project")
        forbidden = {
            "cwd",
            "workspace",
            "workspace_id",
            "surface",
            "surface_id",
            "terminal",
            "terminal_id",
            "machine",
            "machine_id",
            "backend",
            "argv",
            "environment",
            "profile_generation",
            "systemd_properties",
        }

        def keys(value: object) -> set[str]:
            if isinstance(value, dict):
                return set(value) | set().union(*(keys(v) for v in value.values()))
            if isinstance(value, list):
                return set().union(*(keys(v) for v in value))
            return set()

        self.assertTrue(forbidden.isdisjoint(keys(document)))

    def test_request_rejects_execution_and_workspace_controls(self) -> None:
        for option, value in (
            ("--machine", "big-red"),
            ("--cwd", "/tmp/project"),
            ("--argv", "sh"),
            ("--environment", "A=B"),
            ("--profile-generation", "sha256:" + "a" * 64),
            ("--systemd-properties", "MemoryMax=99G"),
        ):
            with self.subTest(option=option):
                result = self.run_cli(*self.request_args(), option, value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"unknown option", result.stderr.lower())
                self.assertNotIn(b"glaeda", result.stderr.lower())
                self.assertNotIn(b"socket", result.stderr.lower())

    def test_observe_correlates_bounded_result(self) -> None:
        result = self.run_cli(
            "glaeda",
            "observe",
            "--request",
            str(REQUEST),
            "--receipt",
            str(RECEIPT),
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stderr, b"")
        self.assertEqual(
            json.loads(result.stdout),
            {
                "document_type": "cmux-glaeda-execution-observation",
                "schema_version": 1,
                "external_request_ref": "cmux:exec:1050:fixture-1",
                "work_ref": "cmux:work:1050",
                "state": "planned",
                "request_sha256": "sha256:c10e23961f34eaabb979f890ce830efeca737ef63f4534f0b8cf9346fadf9d60",
                "workload_receipt_sha256": None,
            },
        )
        self.assertNotIn(b"resolved_workload", result.stdout)
        self.assertNotIn(b"generation", result.stdout)
        self.assertNotIn(b"host", result.stdout)

    def test_observe_accepts_stdin_receipt(self) -> None:
        result = self.run_cli(
            "glaeda",
            "observe",
            "--request",
            str(REQUEST),
            "--receipt",
            "-",
            stdin=RECEIPT.read_bytes(),
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(json.loads(result.stdout)["state"], "planned")

    def test_observe_rejects_source_and_digest_drift(self) -> None:
        original = json.loads(RECEIPT.read_text())
        for mutate in ("source", "digest"):
            with self.subTest(mutate=mutate), tempfile.TemporaryDirectory() as tmp:
                receipt = copy.deepcopy(original)
                if mutate == "source":
                    receipt["source"]["tree"] = "f" * 40
                else:
                    receipt["request_sha256"] = "sha256:" + "f" * 64
                path = Path(tmp) / "receipt.json"
                path.write_text(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")
                result = self.run_cli(
                    "glaeda",
                    "observe",
                    "--request",
                    str(REQUEST),
                    "--receipt",
                    str(path),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b"execution receipt", result.stderr.lower())
                self.assertNotIn(b"glaeda", result.stderr.lower())

    def test_observe_rejects_float_schema_lookalike(self) -> None:
        receipt = json.loads(RECEIPT.read_text())
        receipt["schema_version"] = 1.0
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "receipt.json"
            path.write_text(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")
            result = self.run_cli(
                "glaeda",
                "observe",
                "--request",
                str(REQUEST),
                "--receipt",
                str(path),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"canonical json", result.stderr.lower())
        self.assertNotIn(b"glaeda", result.stderr.lower())

    def test_observe_requires_real_json_booleans_for_zero_authority(self) -> None:
        receipt = json.loads(RECEIPT.read_text())
        receipt["authority"]["authorizes_execution"] = 0
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "receipt.json"
            path.write_text(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")
            result = self.run_cli(
                "glaeda",
                "observe",
                "--request",
                str(REQUEST),
                "--receipt",
                str(path),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"does not match", result.stderr)

    def test_observe_rejects_false_terminal_without_workload_evidence(self) -> None:
        receipt = json.loads(RECEIPT.read_text())
        receipt["state"] = "succeeded"
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "receipt.json"
            path.write_text(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")
            result = self.run_cli(
                "glaeda",
                "observe",
                "--request",
                str(REQUEST),
                "--receipt",
                str(path),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"terminal result is missing workload evidence", result.stderr)
        self.assertNotIn(b"glaeda", result.stderr.lower())

    def test_observe_accepts_terminal_with_bounded_workload_digest(self) -> None:
        receipt = json.loads(RECEIPT.read_text())
        receipt["state"] = "succeeded"
        receipt["workload_receipt_sha256"] = "sha256:" + "b" * 64
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "receipt.json"
            path.write_text(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")
            result = self.run_cli(
                "glaeda",
                "observe",
                "--request",
                str(REQUEST),
                "--receipt",
                str(path),
            )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        observation = json.loads(result.stdout)
        self.assertEqual(observation["state"], "succeeded")
        self.assertEqual(observation["workload_receipt_sha256"], "sha256:" + "b" * 64)

    def test_observe_rejects_noncanonical_and_oversized_receipts(self) -> None:
        receipt = json.loads(RECEIPT.read_text())
        with tempfile.TemporaryDirectory() as tmp:
            pretty = Path(tmp) / "pretty.json"
            pretty.write_text(json.dumps(receipt, indent=2) + "\n")
            pretty_result = self.run_cli(
                "glaeda",
                "observe",
                "--request",
                str(REQUEST),
                "--receipt",
                str(pretty),
            )
            self.assertNotEqual(pretty_result.returncode, 0)
            self.assertIn(b"canonical JSON", pretty_result.stderr)
            self.assertNotIn(b"glaeda", pretty_result.stderr.lower())

            oversized = Path(tmp) / "oversized.json"
            oversized.write_bytes(b"{" + b" " * 5000 + b"}")
            oversized_result = self.run_cli(
                "glaeda",
                "observe",
                "--request",
                str(REQUEST),
                "--receipt",
                str(oversized),
            )
            self.assertNotEqual(oversized_result.returncode, 0)
            self.assertIn(b"exceeds the size limit", oversized_result.stderr)
            self.assertNotIn(b"glaeda", oversized_result.stderr.lower())

    def test_observe_refuses_fifo_and_symlink_paths_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            fifo = Path(tmp) / "receipt.fifo"
            os.mkfifo(fifo)
            fifo_result = self.run_cli(
                "glaeda",
                "observe",
                "--request",
                str(REQUEST),
                "--receipt",
                str(fifo),
            )
            self.assertNotEqual(fifo_result.returncode, 0)
            self.assertIn(b"regular file", fifo_result.stderr)
            self.assertNotIn(b"glaeda", fifo_result.stderr.lower())

            symlink = Path(tmp) / "receipt-link.json"
            symlink.symlink_to(RECEIPT)
            symlink_result = self.run_cli(
                "glaeda",
                "observe",
                "--request",
                str(REQUEST),
                "--receipt",
                str(symlink),
            )
            self.assertNotEqual(symlink_result.returncode, 0)
            self.assertIn(b"input document", symlink_result.stderr)
            self.assertNotIn(b"glaeda", symlink_result.stderr.lower())

    def test_help_is_available_without_socket(self) -> None:
        result = self.run_cli("glaeda", "--help")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn(b"Usage: cmux glaeda <request|observe>", result.stdout)
        self.assertNotIn(b"socket", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
