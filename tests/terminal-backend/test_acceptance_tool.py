#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts/verify-terminal-backend-acceptance.py"
SPEC = importlib.util.spec_from_file_location("terminal_backend_acceptance", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
acceptance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(acceptance)


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class AcceptanceToolTests(unittest.TestCase):
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

    def test_final_verification_binds_all_packaged_binaries_and_artifacts(self) -> None:
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
            created: dict[str, tuple[str, str]] = {}
            for criterion, check in zip(
                acceptance.load_spec()["criteria"], manifest["checks"], strict=True
            ):
                artifacts = []
                for kind in criterion["required_artifact_kinds"]:
                    if kind not in created:
                        path = evidence / f"{len(created):02d}-{kind}.txt"
                        payload = f"evidence for {kind}\n".encode()
                        path.write_bytes(payload)
                        created[kind] = (path.name, digest(payload))
                    relative, sha256 = created[kind]
                    artifacts.append(
                        {
                            "kind": kind,
                            "path": relative,
                            "sha256": sha256,
                            "captured_at": timestamp,
                            "pids": [1001, 1002, 1003],
                        }
                    )
                check.update(
                    {
                        "status": "pass",
                        "commands": [["test-command", criterion["id"]]],
                        "assertions": [criterion["pass_condition"]],
                        "artifacts": artifacts,
                    }
                )
            manifest_path = evidence / "manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            arguments = argparse.Namespace(
                manifest=manifest_path,
                require_final_head=False,
                require_all_p0=True,
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
