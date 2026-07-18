#!/usr/bin/env python3

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import pathlib
import plistlib
import struct
import tempfile
import unittest
from unittest import mock
import zlib


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts/verify-terminal-backend-acceptance.py"
XCTRACE_FIXTURES = REPO_ROOT / "tests/terminal-backend/fixtures/xctrace"
SPEC = importlib.util.spec_from_file_location("terminal_backend_acceptance", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
acceptance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(acceptance)

def png_chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = zlib.crc32(kind)
    checksum = zlib.crc32(payload, checksum) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def write_png(
    path: pathlib.Path,
    *,
    width: int = 2,
    height: int = 1,
    pixels: bytes | None = None,
    marker: str | None = None,
) -> None:
    pixels = pixels if pixels is not None else bytes(width * height * 4)
    assert len(pixels) == width * height * 4
    rows = b"".join(
        b"\x00" + pixels[row * width * 4 : (row + 1) * width * 4]
        for row in range(height)
    )
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + (png_chunk(b"tEXt", f"fixture\x00{marker}".encode()) if marker is not None else b"")
        + png_chunk(b"IDAT", zlib.compress(rows))
        + png_chunk(b"IEND", b"")
    )


def bmff_box(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload) + 8) + kind + payload


def write_video(path: pathlib.Path, *, frames: int = 3, duration: int = 3000) -> None:
    ftyp = bmff_box(b"ftyp", b"qt  \x00\x00\x02\x00qt  ")
    mvhd = bmff_box(
        b"mvhd",
        b"\x00\x00\x00\x00" + b"\x00" * 8 + struct.pack(">II", 1000, duration) + b"\x00" * 80,
    )
    hdlr = bmff_box(b"hdlr", b"\x00" * 8 + b"vide" + b"\x00" * 12)
    stsd = bmff_box(b"stsd", b"\x00" * 4 + struct.pack(">I", 1) + b"avc1")
    stts = bmff_box(
        b"stts",
        b"\x00" * 4 + struct.pack(">I", 1) + struct.pack(">II", frames, 1000),
    )
    stsz = bmff_box(
        b"stsz",
        b"\x00" * 4 + struct.pack(">II", 1, frames),
    )
    stco = bmff_box(b"stco", b"\x00" * 4 + struct.pack(">II", 1, 8))
    stbl = bmff_box(b"stbl", stsd + stts + stsz + stco)
    minf = bmff_box(b"minf", stbl)
    mdia = bmff_box(b"mdia", hdlr + minf)
    trak = bmff_box(b"trak", mdia)
    moov = bmff_box(b"moov", mvhd + trak)
    mdat = bmff_box(b"mdat", b"\x00" * max(frames, 1))
    path.write_bytes(ftyp + moov + mdat)


def fidelity_provenance(
    *,
    build: str,
    executable: str,
    pid: int,
    started_at: str = "2026-07-17T12:00:00Z",
) -> dict[str, object]:
    return {
        "build_sha256": build * 64,
        "executable_sha256": executable * 64,
        "process_pid": pid,
        "process_started_at": started_at,
        "font_sha256": "f" * 64,
        "config_sha256": "c" * 64,
        "geometry": {"width": 2, "height": 1, "scale": 2.0},
        "source_commit": "a" * 40,
    }


def write_junit(path: pathlib.Path, names: list[str], *, failed: set[str] | None = None) -> None:
    failed = failed or set()
    testcases = "".join(
        f'<testcase name="{name}">' + ("<failure/>" if name in failed else "") + "</testcase>"
        for name in names
    )
    path.write_text(f'<testsuite tests="{len(names)}">{testcases}</testsuite>', encoding="utf-8")


def write_test_artifact(
    root: pathlib.Path,
    *,
    criterion_id: str,
    names: list[str],
) -> pathlib.Path:
    runner = root / "runner"
    binary = root / "test-binary"
    stdout = root / "stdout.txt"
    junit = root / "junit.xml"
    runner.write_bytes(b"runner")
    binary.write_bytes(b"binary")
    stdout.write_text("test output\n", encoding="utf-8")
    write_junit(junit, names)
    command = ["runner", "--tests", ",".join(names)]
    raw = root / f"{criterion_id.lower()}-integration.json"
    raw.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "artifact_kind": "integration-test",
                "context": {
                    "runner": {
                        "name": "fixture-runner",
                        "version": "1.0",
                        "file": {"path": runner.name, "sha256": acceptance.sha256_file(runner)},
                    },
                    "binary": {
                        "file": {"path": binary.name, "sha256": acceptance.sha256_file(binary)},
                        "source_commit": "a" * 40,
                    },
                    "command": command,
                    "selected_tests": names,
                    "exit_code": 0,
                    "stdout": {"path": stdout.name, "sha256": acceptance.sha256_file(stdout)},
                    "junit": {"path": junit.name, "sha256": acceptance.sha256_file(junit)},
                },
                "records": [{"name": name} for name in names],
            }
        ),
        encoding="utf-8",
    )
    return raw


def create_process_census_receipt(
    evidence: pathlib.Path,
    *,
    criterion_id: str,
    command: list[str],
    timestamp: str,
    pids: list[int],
) -> tuple[str, str]:
    stem = f"{criterion_id.lower()}-process-census"
    payload = evidence / f"{stem}-raw.json"
    payload.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "artifact_kind": "process-census",
                "context": {},
                "records": [
                    {"role": "swift-host", "pid": pids[0], "pty_master_fds": []},
                    {"role": "terminal-backend", "pid": pids[1], "pty_master_fds": ["4:/dev/ptmx"]},
                    {"role": "renderer-worker", "pid": pids[2], "pty_master_fds": []},
                ],
            }
        ),
        encoding="utf-8",
    )
    metrics = acceptance.derive_payload_metrics(
        criterion_id, "process-census", payload, "test process census"
    )
    assert metrics is not None

    receipt = evidence / f"{stem}-receipt.json"
    receipt.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "criterion_id": criterion_id,
                "artifact_kind": "process-census",
                "source_commit": "a" * 40,
                "captured_at": timestamp,
                "command": command,
                "passed": True,
                "pids": pids,
                "observations": ["observed live process census"],
                "metrics": metrics,
                "attachments": [
                    {
                        "role": "primary",
                        "path": payload.relative_to(evidence).as_posix(),
                        "sha256": acceptance.sha256_path(payload),
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    return receipt.name, acceptance.sha256_file(receipt)


class AcceptanceToolTests(unittest.TestCase):
    def create_linkage_audit_repository(self, root: pathlib.Path) -> str:
        sources = {
            "Sources/Safe.swift": "func projectCanonicalFrame() {}\n",
            "Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Safe.swift": (
                "func hostExternalCompositor() {}\n"
            ),
            "Packages/macOS/CmuxTerminalRenderer/Package.swift": (
                "// swift-tools-version: 6.0\nimport PackageDescription\n"
            ),
            "Packages/macOS/CmuxTerminalRenderer/Sources/"
            "CmuxTerminalRendererWorker/Safe.swift": (
                "func renderSemanticScene() {}\n"
            ),
            "Packages/macOS/CmuxBrowser/Package.swift": (
                "// swift-tools-version: 6.0\nimport PackageDescription\n"
            ),
            "Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/Safe.swift": (
                "func renderCanonicalRows() {}\n"
            ),
        }
        for relative, contents in sources.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding="utf-8")
        acceptance.run(["git", "init", "--quiet"], cwd=root)
        acceptance.run(["git", "config", "user.email", "acceptance@example.com"], cwd=root)
        acceptance.run(["git", "config", "user.name", "Acceptance Fixture"], cwd=root)
        acceptance.run(["git", "add", "."], cwd=root)
        acceptance.run(["git", "commit", "--quiet", "-m", "safe linkage fixture"], cwd=root)
        return acceptance.run(["git", "rev-parse", "HEAD"], cwd=root)

    def test_acceptance_spec_still_contains_all_nineteen_criteria(self) -> None:
        criteria = acceptance.load_spec()["criteria"]
        self.assertEqual(len(criteria), 19)
        self.assertEqual(len({criterion["id"] for criterion in criteria}), 19)

    def test_capture_defaults_cover_v8_baseline_and_v9_mutations(self) -> None:
        parser = acceptance.parser()
        arguments = parser.parse_args(
            [
                "capture",
                "--tag",
                "evid1",
                "--artifact-root",
                "/tmp/cmux-terminal-backend-evidence",
            ]
        )

        self.assertEqual(arguments.protocol_min, 8)
        self.assertEqual(arguments.protocol_max, 9)

    def base_manifest(self) -> dict[str, object]:
        spec = acceptance.load_spec()
        return {
            "schema_version": 1,
            "criteria_sha256": acceptance.sha256_file(acceptance.SPEC_PATH),
            "source": {
                "commit": "a" * 40,
                "clean": True,
                "submodules": {"ghostty": "b" * 40},
            },
            "build": {
                "tag": "evid1",
                "bundle_id": "com.cmuxterm.dev.evid1",
                "app_path": "/tmp/cmux DEV evid1.app",
                "info_plist_sha256": "0" * 64,
                "executables": [
                    {"role": "swift-host", "path": "Contents/MacOS/cmux DEV", "sha256": "1" * 64},
                    {
                        "role": "terminal-backend",
                        "path": "Contents/Resources/bin/cmux-terminal-backend",
                        "sha256": "2" * 64,
                    },
                    {
                        "role": "renderer-worker",
                        "path": "Contents/Resources/bin/cmux-terminal-renderer",
                        "sha256": "3" * 64,
                    },
                ],
                "debug_socket": "/tmp/cmux-debug-evid1.sock",
                "backend_socket": "/tmp/cmux-tui-501/evid1.sock",
            },
            "environment": {
                "os_build": "25A1",
                "hardware_model": "MacTest1,1",
                "captured_at": "2026-07-17T12:00:00Z",
            },
            "protocol": {
                "client_range": [8, 8],
                "daemon_range": [8, 8],
                "negotiated": 8,
                "capabilities": [],
            },
            "roles": {
                "acceptance_author": "acceptance-author",
                "implementer": "implementer",
                "interaction_profiler": "interaction-profiler",
                "artifact_verifier": "artifact-verifier",
            },
            "processes": [],
            "checks": [
                {
                    "id": criterion["id"],
                    "priority": criterion["priority"],
                    "status": "fail",
                    "commands": [],
                    "assertions": ["evidence has not been captured"],
                    "artifacts": [],
                }
                for criterion in spec["criteria"]
            ],
        }

    def test_manifest_shape_accepts_exact_initial_manifest(self) -> None:
        acceptance.validate_shape(self.base_manifest(), acceptance.load_spec())

    def test_manifest_shape_rejects_nested_unknown_key(self) -> None:
        manifest = self.base_manifest()
        manifest["build"]["unexpected"] = True
        with self.assertRaisesRegex(acceptance.AcceptanceError, "build keys differ"):
            acceptance.validate_shape(manifest, acceptance.load_spec())

    def test_manifest_shape_rejects_negotiated_version_outside_range(self) -> None:
        manifest = self.base_manifest()
        manifest["protocol"]["negotiated"] = 9
        with self.assertRaisesRegex(acceptance.AcceptanceError, "outside"):
            acceptance.validate_shape(manifest, acceptance.load_spec())

    def test_artifact_resolution_rejects_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            outside = root.parent / "outside-evidence.txt"
            outside.write_text("outside", encoding="utf-8")
            self.addCleanup(outside.unlink, missing_ok=True)
            with self.assertRaisesRegex(acceptance.AcceptanceError, "escapes"):
                acceptance.resolve_artifact(root, "../outside-evidence.txt")

    def test_semantic_receipt_rejects_filename_only_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fake = root / "process-census.txt"
            fake.write_text("looks plausible", encoding="utf-8")
            with self.assertRaisesRegex(acceptance.AcceptanceError, "JSON evidence receipt"):
                acceptance.validate_evidence_receipt(
                    receipt_path=fake,
                    run_root=root,
                    criterion_id="PROC-1",
                    artifact_kind="process-census",
                    source_commit="a" * 40,
                    artifact_pids=[1001],
                    commands=[["collect-census"]],
                    expected_pass=True,
                )

    def test_semantic_receipt_requires_kind_specific_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            relative, _ = create_process_census_receipt(
                root,
                criterion_id="PROC-1",
                command=["collect-census"],
                timestamp="2026-07-17T12:00:00Z",
                pids=[1001, 1002, 1003],
            )
            receipt_path = root / relative
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            del receipt["metrics"]["swift_pty_master_count"]
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            with self.assertRaisesRegex(acceptance.AcceptanceError, "lacks metrics"):
                acceptance.validate_evidence_receipt(
                    receipt_path=receipt_path,
                    run_root=root,
                    criterion_id="PROC-1",
                    artifact_kind="process-census",
                    source_commit="a" * 40,
                    artifact_pids=[1001, 1002, 1003],
                    commands=[["collect-census"]],
                    expected_pass=True,
                )

    def test_semantic_receipt_rejects_passing_metric_violation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            relative, _ = create_process_census_receipt(
                root,
                criterion_id="PROC-1",
                command=["collect-allocations"],
                timestamp="2026-07-17T12:00:00Z",
                pids=[1001, 1002, 1003],
            )
            receipt_path = root / relative
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["metrics"]["swift_pty_master_count"] = 1
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            with self.assertRaisesRegex(acceptance.AcceptanceError, "not derived"):
                acceptance.validate_evidence_receipt(
                    receipt_path=receipt_path,
                    run_root=root,
                    criterion_id="PROC-1",
                    artifact_kind="process-census",
                    source_commit="a" * 40,
                    artifact_pids=[1001, 1002, 1003],
                    commands=[["collect-allocations"]],
                    expected_pass=True,
                )

    def test_valid_receipt_metrics_are_rederived_from_raw_census(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            relative, _ = create_process_census_receipt(
                root,
                criterion_id="PROC-1",
                command=["collect-census"],
                timestamp="2026-07-17T12:00:00Z",
                pids=[1001, 1002, 1003],
            )
            acceptance.validate_evidence_receipt(
                receipt_path=root / relative,
                run_root=root,
                criterion_id="PROC-1",
                artifact_kind="process-census",
                source_commit="a" * 40,
                artifact_pids=[1001, 1002, 1003],
                commands=[["collect-census"]],
                expected_pass=True,
            )

    def test_proc1_census_requires_only_backend_to_own_pty_masters(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            create_process_census_receipt(
                root,
                criterion_id="PROC-1",
                command=["collect-census"],
                timestamp="2026-07-17T12:00:00Z",
                pids=[1001, 1002, 1003],
            )
            payload = root / "proc-1-process-census-raw.json"
            raw = json.loads(payload.read_text(encoding="utf-8"))

            raw["records"][1]["pty_master_fds"] = []
            payload.write_text(json.dumps(raw), encoding="utf-8")
            metrics = acceptance.derive_payload_metrics(
                "PROC-1", "process-census", payload, "missing backend PTY ownership"
            )
            assert metrics is not None
            with self.assertRaisesRegex(acceptance.AcceptanceError, "backend must own"):
                acceptance.validate_metric_invariants(
                    "PROC-1", "process-census", metrics, "missing backend PTY ownership"
                )

            raw["records"][1]["pty_master_fds"] = ["4:/dev/ptmx"]
            raw["records"][2]["pty_master_fds"] = ["9:/dev/ptmx"]
            payload.write_text(json.dumps(raw), encoding="utf-8")
            metrics = acceptance.derive_payload_metrics(
                "PROC-1", "process-census", payload, "renderer PTY ownership"
            )
            assert metrics is not None
            with self.assertRaisesRegex(
                acceptance.AcceptanceError,
                "renderer_pty_master_count must be zero",
            ):
                acceptance.validate_metric_invariants(
                    "PROC-1", "process-census", metrics, "renderer PTY ownership"
                )

    def test_raw_json_rejects_embedded_self_authored_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "raw.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifact_kind": "runtime-assertion",
                        "context": {},
                        "records": [{"passed": True}],
                        "metrics": {"assertion_count": 999, "failure_count": 0},
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(acceptance.AcceptanceError, "keys differ"):
                acceptance.derive_payload_metrics(
                    "STATE-2", "runtime-assertion", path, "runtime assertion"
                )

    def test_linkage_audit_derives_nonempty_scan_records_from_manifest_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            commit = self.create_linkage_audit_repository(root)
            payload = acceptance.build_linkage_audit_artifact(root, commit)
            self.assertEqual(payload["artifact_kind"], "linkage-audit")
            self.assertEqual(payload["context"]["source_commit"], commit)
            self.assertEqual(
                {record["category"] for record in payload["records"]},
                set(acceptance.LINKAGE_AUDIT_METRIC_BY_CATEGORY),
            )
            self.assertTrue(payload["records"])

            raw = root / "linkage.json"
            raw.write_text(json.dumps(payload), encoding="utf-8")
            metrics = acceptance.derive_payload_metrics(
                "STATE-2",
                "linkage-audit",
                raw,
                "safe linkage fixture",
                source_commit=commit,
                repo_root=root,
            )
            self.assertEqual(
                metrics,
                {
                    metric: 0
                    for metric in acceptance.LINKAGE_AUDIT_METRIC_BY_CATEGORY.values()
                },
            )

    def test_linkage_audit_rejects_empty_and_hand_authored_records(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            commit = self.create_linkage_audit_repository(root)
            canonical = acceptance.build_linkage_audit_artifact(root, commit)
            raw = root / "linkage.json"

            empty = json.loads(json.dumps(canonical))
            empty["records"] = []
            raw.write_text(json.dumps(empty), encoding="utf-8")
            with self.assertRaisesRegex(
                acceptance.AcceptanceError,
                "deterministic commit scan",
            ):
                acceptance.derive_payload_metrics(
                    "CLEAN-1",
                    "linkage-audit",
                    raw,
                    "empty linkage fixture",
                    source_commit=commit,
                    repo_root=root,
                )

            hand_authored = json.loads(json.dumps(canonical))
            hand_authored["records"][0]["scanned_file_count"] = 0
            raw.write_text(json.dumps(hand_authored), encoding="utf-8")
            with self.assertRaisesRegex(
                acceptance.AcceptanceError,
                "deterministic commit scan",
            ):
                acceptance.derive_payload_metrics(
                    "CLEAN-1",
                    "linkage-audit",
                    raw,
                    "hand-authored linkage fixture",
                    source_commit=commit,
                    repo_root=root,
                )

    def test_linkage_audit_scans_commit_and_detects_every_forbidden_category(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            safe_commit = self.create_linkage_audit_repository(root)
            forbidden_sources = {
                ".gitattributes": """
Sources/ForbiddenOwnership.swift export-ignore
Packages/macOS/CmuxTerminalRenderer/Sources/CmuxTerminalRendererWorker/Forbidden.swift export-ignore
Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/Forbidden.swift export-ignore
""",
                "Sources/ForbiddenOwnership.swift": """
func constructLocalFallback() {
    _ = EmbeddedTerminalPanelFactory(dependencies: dependencies)
    _ = ghostty_app_new(&runtimeConfig, config)
    _ = ghostty_surface_new(app, &surfaceConfig)
    _ = openpty(&master, &slave, nil, nil, nil)
}
""",
                "Packages/macOS/CmuxTerminalRenderer/Sources/"
                "CmuxTerminalRendererWorker/Forbidden.swift": """
func consumeRendererPTY() {
    _ = ghostty_surface_new(app, &surfaceConfig)
    parser.vt_write(bytes)
}
""",
                "Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/Forbidden.swift": """
func consumeBrowserPTY() {
    parser.vt_write(bytes)
    _ = VTParser()
}
""",
            }
            for relative, contents in forbidden_sources.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents, encoding="utf-8")

            safe_payload = acceptance.build_linkage_audit_artifact(root, safe_commit)
            self.assertTrue(
                all(not record["findings"] for record in safe_payload["records"]),
                "uncommitted forbidden source must not contaminate the manifest-bound scan",
            )

            acceptance.run(["git", "add", "."], cwd=root)
            acceptance.run(
                ["git", "commit", "--quiet", "-m", "forbidden linkage fixture"],
                cwd=root,
            )
            forbidden_commit = acceptance.run(["git", "rev-parse", "HEAD"], cwd=root)
            payload = acceptance.build_linkage_audit_artifact(root, forbidden_commit)
            findings_by_category = {
                record["category"]: record["findings"] for record in payload["records"]
            }
            self.assertTrue(
                all(findings_by_category[category] for category in findings_by_category),
                findings_by_category,
            )

    def test_complete_png_is_decoded_and_header_only_png_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            expected = root / "expected.png"
            actual = root / "actual.png"
            actual_match = root / "actual-match.png"
            write_png(expected)
            write_png(actual, pixels=b"\x00\x00\x00\x00\x01\x02\x03\x00")
            write_png(actual_match, marker="separate-external-capture")
            raw = root / "diff.json"
            raw.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifact_kind": "image-diff",
                        "context": {
                            "expected_provenance": fidelity_provenance(
                                build="1", executable="2", pid=1001
                            ),
                            "actual_provenance": fidelity_provenance(
                                build="3", executable="4", pid=1002
                            ),
                        },
                        "records": [
                            {
                                "name": name,
                                "expected_path": expected.name,
                                "actual_path": actual.name if name == "ascii" else actual_match.name,
                            }
                            for name in sorted(acceptance.FIDELITY_CORPUS_CASES)
                        ],
                    }
                ),
                encoding="utf-8",
            )
            metrics = acceptance.derive_payload_metrics(
                "FID-1", "image-diff", raw, "image diff"
            )
            self.assertEqual(metrics["different_pixel_count"], 1)
            self.assertEqual(metrics["maximum_channel_delta"], 3)
            self.assertEqual(metrics["mean_absolute_error"], 0.075)

            header_only = root / "header-only.png"
            header_only.write_bytes(
                b"\x89PNG\r\n\x1a\n"
                b"\x00\x00\x00\x0dIHDR"
                b"\x00\x00\x00\x01\x00\x00\x00\x01"
            )
            with self.assertRaisesRegex(acceptance.AcceptanceError, "complete PNG"):
                acceptance.decode_png(header_only, "header-only image")

    def test_fid1_rejects_reused_capture_and_cross_binds_golden_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            expected = root / "expected.png"
            actual = root / "actual.png"
            write_png(expected)
            write_png(actual, marker="separate-render")
            expected_provenance = fidelity_provenance(build="1", executable="2", pid=1001)
            actual_provenance = fidelity_provenance(build="3", executable="4", pid=1002)
            records = [
                {"name": name, "expected_path": expected.name, "actual_path": actual.name}
                for name in sorted(acceptance.FIDELITY_CORPUS_CASES)
            ]
            diff = root / "diff.json"
            diff.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifact_kind": "image-diff",
                        "context": {
                            "expected_provenance": expected_provenance,
                            "actual_provenance": actual_provenance,
                        },
                        "records": records,
                    }
                ),
                encoding="utf-8",
            )
            diff_metrics = acceptance.derive_payload_metrics("FID-1", "image-diff", diff, "diff")

            golden = root / "golden.json"
            golden.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifact_kind": "golden-image",
                        "context": {"provenance": expected_provenance},
                        "records": [
                            {"name": name, "path": expected.name}
                            for name in sorted(acceptance.FIDELITY_CORPUS_CASES)
                        ],
                    }
                ),
                encoding="utf-8",
            )
            golden_metrics = acceptance.derive_payload_metrics(
                "FID-1", "golden-image", golden, "golden"
            )
            acceptance.validate_cross_artifact_invariants(
                "FID-1",
                {"golden-image": golden_metrics, "image-diff": diff_metrics},
                "FID-1 fixture",
                source_commit="a" * 40,
            )

            reused = json.loads(diff.read_text(encoding="utf-8"))
            reused["records"][0]["actual_path"] = expected.name
            diff.write_text(json.dumps(reused), encoding="utf-8")
            with self.assertRaisesRegex(acceptance.AcceptanceError, "reuses one image path"):
                acceptance.derive_payload_metrics("FID-1", "image-diff", diff, "diff")

    def test_perf1_derives_improvement_only_from_cross_bound_runs(self) -> None:
        common = {
            "current_main_commit": "b" * 40,
            "hardware_model": "MacTest1,1",
            "host_identity_sha256": "1" * 64,
            "os_build": "25A1",
            "display_configuration_sha256": "2" * 64,
            "workload_id": "terminal-backend-perf1-v1",
            "workload_sha256": "3" * 64,
            "workload_seed": 17,
            "duration_seconds": 60.0,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            baseline = root / "baseline.json"
            baseline.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifact_kind": "baseline",
                        "context": {**common, "source_commit": "b" * 40},
                        "records": [{"latency_ms": 20.0} for _ in range(100)],
                    }
                ),
                encoding="utf-8",
            )
            branch = root / "branch.json"
            branch.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifact_kind": "latency-distribution",
                        "context": {
                            **common,
                            "source_commit": "a" * 40,
                            "workspace_count": 100,
                            "continuous_output_terminal_count": 8,
                        },
                        "records": [
                            {"event_ns": index * 20_000_000, "visible_ns": index * 20_000_000 + 10_000_000}
                            for index in range(100)
                        ],
                    }
                ),
                encoding="utf-8",
            )
            baseline_metrics = acceptance.derive_payload_metrics(
                "PERF-1", "baseline", baseline, "baseline"
            )
            branch_metrics = acceptance.derive_payload_metrics(
                "PERF-1", "latency-distribution", branch, "branch"
            )
            self.assertNotIn("baseline_p95_ms", branch_metrics)
            self.assertNotIn("improvement_percent", branch_metrics)
            acceptance.validate_cross_artifact_invariants(
                "PERF-1",
                {"baseline": baseline_metrics, "latency-distribution": branch_metrics},
                "PERF-1 fixture",
                source_commit="a" * 40,
                environment={"hardware_model": "MacTest1,1", "os_build": "25A1"},
            )
            branch_metrics["workload_seed"] = 18
            with self.assertRaisesRegex(acceptance.AcceptanceError, "differ in"):
                acceptance.validate_cross_artifact_invariants(
                    "PERF-1",
                    {"baseline": baseline_metrics, "latency-distribution": branch_metrics},
                    "PERF-1 fixture",
                    source_commit="a" * 40,
                )

    def test_machine_test_evidence_binds_fid2_subcases_runner_junit_and_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            names = sorted(acceptance.FID2_MACHINE_SUBCASES)
            raw = write_test_artifact(root, criterion_id="FID-2", names=names)
            metrics = acceptance.derive_payload_metrics(
                "FID-2", "integration-test", raw, "FID-2 tests"
            )
            self.assertEqual(metrics["test_count"], len(names))
            self.assertEqual(metrics["failure_count"], 0)
            self.assertEqual(metrics["binary_source_commit"], "a" * 40)
            self.assertEqual(metrics["selected_tests_sha256"], acceptance.sha256_json(names))

            payload = json.loads(raw.read_text(encoding="utf-8"))
            payload["context"]["selected_tests"] = names[:-1]
            raw.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(acceptance.AcceptanceError, "named subcases differ"):
                acceptance.derive_payload_metrics(
                    "FID-2", "integration-test", raw, "FID-2 tests"
                )

    def test_multi1_requires_rejected_attempt_without_geometry_change(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            leases = root / "leases.json"
            leases.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifact_kind": "lease-transcript",
                        "context": {},
                        "records": [
                            {"lease": "input", "action": "acquired", "authorized": True, "result": "accepted", "state_changed": True},
                            {"lease": "geometry", "action": "acquired", "authorized": True, "result": "accepted", "state_changed": True},
                            {"lease": "geometry", "action": "resize-attempt", "authorized": False, "result": "rejected", "state_changed": False},
                        ],
                    }
                ),
                encoding="utf-8",
            )
            sizes = root / "sizes.json"
            sizes.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifact_kind": "pty-size-samples",
                        "context": {},
                        "records": [
                            {
                                "previous_columns": 80,
                                "previous_rows": 24,
                                "attempted_columns": 100,
                                "attempted_rows": 30,
                                "resulting_columns": 80,
                                "resulting_rows": 24,
                                "authorized": False,
                            },
                            {
                                "previous_columns": 80,
                                "previous_rows": 24,
                                "attempted_columns": 120,
                                "attempted_rows": 40,
                                "resulting_columns": 120,
                                "resulting_rows": 40,
                                "authorized": True,
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )
            lease_metrics = acceptance.derive_payload_metrics(
                "MULTI-1", "lease-transcript", leases, "leases"
            )
            size_metrics = acceptance.derive_payload_metrics(
                "MULTI-1", "pty-size-samples", sizes, "sizes"
            )
            acceptance.validate_metric_invariants("MULTI-1", "lease-transcript", lease_metrics, "leases")
            acceptance.validate_metric_invariants("MULTI-1", "pty-size-samples", size_metrics, "sizes")
            acceptance.validate_cross_artifact_invariants(
                "MULTI-1",
                {"lease-transcript": lease_metrics, "pty-size-samples": size_metrics},
                "MULTI-1 fixture",
            )

    def test_multi2_requires_global_sequence_source_type_and_pty_bytes(self) -> None:
        expected = [
            {"event_id": "e1", "source": "gui", "event_type": "key-down", "pty_bytes_hex": "61"},
            {"event_id": "e2", "source": "tui", "event_type": "key-up", "pty_bytes_hex": ""},
            {"event_id": "e3", "source": "automation", "event_type": "mouse", "pty_bytes_hex": "1b5b4d"},
            {"event_id": "e4", "source": "gui", "event_type": "paste", "pty_bytes_hex": "6869"},
        ]
        observed = [
            {**event, "global_sequence": index}
            for index, event in enumerate(expected, start=1)
        ]
        with tempfile.TemporaryDirectory() as temporary:
            raw = pathlib.Path(temporary) / "input.json"
            raw.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifact_kind": "input-transcript",
                        "context": {},
                        "records": [{"group_id": "paste-and-rollover", "expected_events": expected, "observed_events": observed}],
                    }
                ),
                encoding="utf-8",
            )
            metrics = acceptance.derive_payload_metrics(
                "MULTI-2", "input-transcript", raw, "input"
            )
            acceptance.validate_metric_invariants(
                "MULTI-2", "input-transcript", metrics, "input"
            )
            self.assertEqual(metrics["global_sequence_gap_count"], 0)
            self.assertEqual(metrics["source_coverage_count"], 3)
            self.assertEqual(metrics["event_type_coverage_count"], 4)
            self.assertEqual(metrics["pty_bytes_mismatch_count"], 0)

    def test_perf2_requires_live_collector_and_phase_process_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            collector_file = root / "collector"
            collector_file.write_bytes(b"live collector")
            timestamp = "2026-07-17T12:00:00Z"
            renderer_hash = "4" * 64
            renderers = [
                {
                    "pid": 2000 + index,
                    "started_at": timestamp,
                    "executable_sha256": renderer_hash,
                    "workspace_ids": [f"visible-{index:03d}"],
                }
                for index in range(100)
            ]
            records = [
                {
                    "role": "swift-host",
                    "pid": 1001,
                    "pty_master_fds": [],
                    "started_at": timestamp,
                    "executable_sha256": "1" * 64,
                },
                {
                    "role": "terminal-backend",
                    "pid": 1002,
                    "pty_master_fds": ["4:/dev/ptmx"],
                    "started_at": timestamp,
                    "executable_sha256": "2" * 64,
                },
                {
                    "role": "evidence-collector",
                    "pid": 9000,
                    "pty_master_fds": [],
                    "started_at": timestamp,
                    "executable_sha256": acceptance.sha256_file(collector_file),
                },
                *[
                    {
                        "role": "renderer-worker",
                        "pid": renderer["pid"],
                        "pty_master_fds": [],
                        "started_at": renderer["started_at"],
                        "executable_sha256": renderer_hash,
                    }
                    for renderer in renderers
                ],
            ]
            phase_base = {"collector_pid": 9000, "backend_pid": 1002}
            raw = root / "perf2.json"
            raw.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifact_kind": "process-census",
                        "context": {
                            "collector": {
                                "name": "cmux-process-census",
                                "version": "1",
                                "file": {"path": collector_file.name, "sha256": acceptance.sha256_file(collector_file)},
                                "source_commit": "a" * 40,
                                "pid": 9000,
                                "started_at": timestamp,
                                "command": ["collector", "--live"],
                                "hardware_model": "MacTest1,1",
                                "host_identity_sha256": "5" * 64,
                                "os_build": "25A1",
                            },
                            "phases": {
                                "dormant": {
                                    **phase_base,
                                    "captured_at": "2026-07-17T12:00:01Z",
                                    "workspace_ids": [f"dormant-{index:04d}" for index in range(1000)],
                                    "presentation_ids": [],
                                    "renderer_processes": [],
                                },
                                "visible": {
                                    **phase_base,
                                    "captured_at": "2026-07-17T12:00:02Z",
                                    "workspace_ids": [f"visible-{index:03d}" for index in range(100)],
                                    "presentation_ids": [f"presentation-{index:03d}" for index in range(100)],
                                    "renderer_processes": renderers,
                                },
                                "shared": {
                                    **phase_base,
                                    "captured_at": "2026-07-17T12:00:03Z",
                                    "workspace_ids": ["visible-000"],
                                    "presentation_ids": ["shared-a", "shared-b"],
                                    "renderer_processes": [renderers[0]],
                                },
                                "retired": {
                                    **phase_base,
                                    "captured_at": "2026-07-17T12:00:04Z",
                                    "workspace_ids": [f"dormant-{index:04d}" for index in range(1000)],
                                    "presentation_ids": [],
                                    "renderer_processes": [],
                                },
                            },
                        },
                        "records": records,
                    }
                ),
                encoding="utf-8",
            )
            metrics = acceptance.derive_payload_metrics(
                "PERF-2", "process-census", raw, "PERF-2 census"
            )
            acceptance.validate_metric_invariants(
                "PERF-2", "process-census", metrics, "PERF-2 census"
            )
            self.assertEqual(metrics["collector_pid"], 9000)
            self.assertEqual(metrics["collector_sample_count"], 4)
            self.assertEqual(metrics["phase_provenance_count"], 4)
            expected_pids = sorted(record["pid"] for record in records)
            self.assertEqual(
                metrics["observed_pid_set_sha256"], acceptance.sha256_json(expected_pids)
            )

            payload = json.loads(raw.read_text(encoding="utf-8"))
            payload["context"]["phases"]["shared"]["collector_pid"] = 9001
            raw.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(acceptance.AcceptanceError, "different collector"):
                acceptance.derive_payload_metrics(
                    "PERF-2", "process-census", raw, "PERF-2 census"
                )

    def test_png_crc_corruption_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "corrupt.png"
            write_png(path)
            payload = bytearray(path.read_bytes())
            payload[-5] ^= 0x01
            path.write_bytes(payload)
            with self.assertRaisesRegex(acceptance.AcceptanceError, "CRC mismatch"):
                acceptance.decode_png(path, "corrupt image")

    def test_video_requires_complete_video_track_and_derives_timing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            valid = root / "capture.mov"
            write_video(valid, frames=3, duration=3000)
            self.assertEqual(acceptance.validate_video(valid, "capture"), (3000, 3))

            header_only = root / "header-only.mov"
            header_only.write_bytes(b"\x00\x00\x00\x18ftypqt  ")
            with self.assertRaisesRegex(acceptance.AcceptanceError, "too small"):
                acceptance.validate_video(header_only, "header-only video")

    def test_trace_directory_must_parse_with_xctrace(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            trace = pathlib.Path(temporary) / "fake.trace"
            trace.mkdir()
            (trace / "marker").write_text("not a trace", encoding="utf-8")
            failed = mock.Mock(returncode=1, stdout=b"", stderr=b"invalid trace")
            with mock.patch.object(acceptance.subprocess, "run", return_value=failed):
                with self.assertRaisesRegex(acceptance.AcceptanceError, "not a readable"):
                    acceptance.validate_trace(trace, "fake trace")

            parsed = mock.Mock(
                returncode=0,
                stdout=b"<?xml version='1.0'?><trace-toc><run number='1'/></trace-toc>",
                stderr=b"",
            )
            with mock.patch.object(acceptance.subprocess, "run", return_value=parsed):
                acceptance.validate_trace(trace, "parsed trace")
                with self.assertRaisesRegex(acceptance.AcceptanceError, "process roles"):
                    acceptance.derive_payload_metrics(
                        "PROC-2", "metal-system-trace", trace, "parsed trace"
                    )

    def test_time_profiler_metrics_are_derived_from_exported_tables(self) -> None:
        metrics = acceptance.derive_time_profiler_metrics_from_exports(
            acceptance.ET.parse(XCTRACE_FIXTURES / "time-profile.xml").getroot(),
            acceptance.ET.parse(XCTRACE_FIXTURES / "sidebar-signposts.xml").getroot(),
            process_roles={
                1001: "swift-host",
                1002: "terminal-backend",
                1003: "renderer-worker",
            },
            label="fixture Time Profiler trace",
        )

        self.assertEqual(
            metrics,
            {
                "swift_terminal_shaping_samples": 1,
                "swift_terminal_render_encoding_samples": 0,
                "renderer_terminal_render_samples": 2,
                "swift_main_thread_sample_count": 2,
                "swift_main_thread_p50_ms": 10.0,
                "swift_main_thread_p95_ms": 20.0,
                "swift_main_thread_p99_ms": 20.0,
                "swift_main_thread_max_ms": 20.0,
            },
        )

    def test_sidebar_signpost_extractor_uses_exact_main_thread_interval(self) -> None:
        latencies = acceptance.derive_sidebar_signpost_latencies_ms(
            acceptance.ET.parse(XCTRACE_FIXTURES / "sidebar-signposts.xml").getroot(),
            swift_pid=1001,
            label="fixture signposts",
        )

        self.assertEqual(latencies, [10.0, 20.0])

    def test_allocation_trace_derives_zero_only_from_bound_swift_ghostty_snapshot(self) -> None:
        root = acceptance.ET.parse(
            XCTRACE_FIXTURES / "ghostty-process-census-signposts.xml"
        ).getroot()
        metrics = acceptance.derive_ghostty_process_census_metrics(
            root,
            process_roles={
                1001: "swift-host",
                1002: "terminal-backend",
                1003: "renderer-worker",
            },
            label="fixture Allocations trace",
        )
        self.assertEqual(
            metrics,
            {
                "swift_ghostty_runtime_app_creation_attempts": 0,
                "swift_canonical_ghostty_allocations": 0,
                "swift_pty_master_allocations": 0,
            },
        )

        with self.assertRaisesRegex(acceptance.AcceptanceError, "no .* interval"):
            acceptance.derive_ghostty_process_census_metrics(
                root,
                process_roles={1002: "terminal-backend", 1003: "swift-host"},
                label="wrong-PID Allocations trace",
            )

    def test_allocation_trace_rejects_incomplete_or_overflowed_snapshot(self) -> None:
        fixture = XCTRACE_FIXTURES / "ghostty-process-census-signposts.xml"
        incomplete = acceptance.ET.parse(fixture).getroot()
        for row in list(incomplete.iter("row")):
            if any(
                child.text == "ghostty-process-census-schema-v2"
                for child in row
            ):
                for child in row:
                    if child.tag == "signpost-name":
                        child.text = "ghostty-process-census-snapshot-overflow"
                break
        with self.assertRaisesRegex(acceptance.AcceptanceError, "invalid|overflowed"):
            acceptance.derive_ghostty_process_census_metrics(
                incomplete,
                process_roles={1001: "swift-host"},
                label="overflow fixture",
            )

    def test_ghostty_constructor_linkage_audit_covers_both_surface_apis_and_openpty(self) -> None:
        acceptance.audit_ghostty_process_census_linkage()
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            relative_paths = (
                "ghostty/src/apprt/embedded.zig",
                "ghostty/src/pty.zig",
                "ghostty/src/process_census.zig",
                "ghostty/include/ghostty.h",
            )
            for relative in relative_paths:
                source = REPO_ROOT / relative
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
            embedded = root / "ghostty/src/apprt/embedded.zig"
            embedded.write_text(
                embedded.read_text(encoding="utf-8").replace(
                    "process_census.recordSurfaceConstructor(opts.io_mode == .manual);",
                    "// census bypass",
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(acceptance.AcceptanceError, "not census-instrumented"):
                acceptance.audit_ghostty_process_census_linkage(root)

            embedded.write_text(
                (REPO_ROOT / "ghostty/src/apprt/embedded.zig")
                .read_text(encoding="utf-8")
                .replace(
                    "process_census.recordRuntimeAppConstructor();",
                    "// runtime app census bypass",
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(acceptance.AcceptanceError, "runtime app constructor"):
                acceptance.audit_ghostty_process_census_linkage(root)

    def test_metal_metrics_are_derived_from_exact_encoder_labels_and_pids(self) -> None:
        metrics = acceptance.derive_metal_metrics_from_export(
            acceptance.ET.parse(XCTRACE_FIXTURES / "metal-encoders.xml").getroot(),
            process_roles={
                1001: "swift-host",
                1002: "terminal-backend",
                1003: "renderer-worker",
            },
            label="fixture Metal trace",
        )

        self.assertEqual(
            metrics,
            {
                "swift_terminal_draw_count": 0,
                "swift_full_surface_blit_count": 2,
                "renderer_terminal_draw_count": 3,
            },
        )

    def test_proc2_cross_artifact_check_uses_raw_frame_counters(self) -> None:
        with self.assertRaisesRegex(acceptance.AcceptanceError, "exceed raw admitted"):
            acceptance.validate_cross_artifact_invariants(
                "PROC-2",
                {
                    "metal-system-trace": {
                        "swift_terminal_draw_count": 0,
                        "swift_full_surface_blit_count": 3,
                        "renderer_terminal_draw_count": 3,
                    },
                    "frame-counters": {"admitted_frames": 2},
                },
                "PROC-2 fixture",
            )

    def test_lsof_parser_counts_only_pty_master_fds(self) -> None:
        output = "\n".join(
            [
                "p42",
                "f3",
                "n/dev/ptmx",
                "f4",
                "n/dev/ttys012",
                "f5",
                "n/tmp/file",
            ]
        )
        self.assertEqual(acceptance.parse_lsof_pty_masters(output), ["3:/dev/ptmx"])

    def test_derive_receipt_writes_only_repository_derived_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest = self.base_manifest()
            timestamp = "2026-07-17T12:00:00Z"
            manifest["processes"] = [
                {
                    "role": role,
                    "build_role": role,
                    "pid": pid,
                    "started_at": timestamp,
                    "executable_path": f"/tmp/{role}",
                    "executable_sha256": str(index) * 64,
                }
                for index, (role, pid) in enumerate(
                    (
                        ("swift-host", 1001),
                        ("terminal-backend", 1002),
                        ("renderer-worker", 1003),
                    ),
                    start=1,
                )
            ]
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            raw = root / "assertions.json"
            raw.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "artifact_kind": "runtime-assertion",
                        "context": {},
                        "records": [{"passed": True}, {"passed": True}],
                    }
                ),
                encoding="utf-8",
            )
            arguments = argparse.Namespace(
                manifest=manifest_path,
                id="STATE-2",
                kind="runtime-assertion",
                status="pass",
                primary=raw.name,
                supporting=[],
                output="assertions-receipt.json",
                pid=[1001, 1002, 1003],
                command_json=['["run-runtime-assertions"]'],
                observation=["All runtime assertions passed."],
                replace=False,
            )
            with mock.patch.object(
                acceptance,
                "assert_clean_source",
                return_value=("a" * 40, {"ghostty": "b" * 40}),
            ):
                receipt_path = acceptance.derive_receipt(arguments)
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(
                receipt["metrics"], {"assertion_count": 2, "failure_count": 0}
            )

    def test_final_verification_binds_all_packaged_binaries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            app = root / "cmux DEV evid1.app"
            contents = app / "Contents"
            main = contents / "MacOS/cmux DEV"
            backend = contents / "Resources/bin/cmux-terminal-backend"
            renderer = contents / "Resources/bin/cmux-terminal-renderer"
            for path, payload in (
                (main, b"swift-host"),
                (backend, b"terminal-backend"),
                (renderer, b"renderer-worker"),
            ):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
                path.chmod(0o755)
            with (contents / "Info.plist").open("wb") as handle:
                plistlib.dump(
                    {
                        "CFBundleIdentifier": "com.cmuxterm.dev.evid1",
                        "CFBundleExecutable": "cmux DEV",
                        "CMUXSourceCommit": "a" * 40,
                        "CMUXSourceDirty": "NO",
                    },
                    handle,
                )

            manifest = self.base_manifest()
            manifest["build"]["app_path"] = str(app)
            manifest["build"]["info_plist_sha256"] = acceptance.sha256_file(
                contents / "Info.plist"
            )
            manifest["build"]["executables"] = [
                {
                    "role": role,
                    "path": str(path.relative_to(app)),
                    "sha256": acceptance.sha256_file(path),
                }
                for role, path in (
                    ("swift-host", main),
                    ("terminal-backend", backend),
                    ("renderer-worker", renderer),
                )
            ]
            timestamp = "2026-07-17T12:00:00Z"
            manifest["processes"] = [
                {
                    "role": role,
                    "build_role": role,
                    "pid": pid,
                    "started_at": timestamp,
                    "executable_path": str(path),
                    "executable_sha256": acceptance.sha256_file(path),
                }
                for role, pid, path in (
                    ("swift-host", 1001, main),
                    ("terminal-backend", 1002, backend),
                    ("renderer-worker", 1003, renderer),
                )
            ]

            evidence = root / "evidence" / "terminal-backend" / ("a" * 40)
            evidence.mkdir(parents=True)
            manifest_path = evidence / "manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            arguments = argparse.Namespace(
                manifest=manifest_path,
                require_final_head=False,
                require_all_p0=False,
            )
            acceptance.verify(arguments)

            renderer.write_bytes(b"tampered-renderer")
            with self.assertRaisesRegex(acceptance.AcceptanceError, "renderer-worker.*changed"):
                acceptance.verify(arguments)

    def test_manifest_shape_rejects_unsorted_artifact_pids(self) -> None:
        manifest = self.base_manifest()
        manifest["checks"][0]["artifacts"] = [
            {
                "kind": "process-census",
                "path": "census.txt",
                "sha256": "0" * 64,
                "captured_at": "2026-07-17T12:00:00Z",
                "pids": [9999, 9998],
            }
        ]
        with self.assertRaisesRegex(acceptance.AcceptanceError, "sorted unique"):
            acceptance.validate_shape(manifest, acceptance.load_spec())


if __name__ == "__main__":
    unittest.main()
