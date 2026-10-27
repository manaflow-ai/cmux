#!/usr/bin/env python3
"""The fast tree hand-off emits the same commit provenance shape as publish."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/build-cmux-tui-manifest.py"


def test_manifest_records_every_staged_binary_and_provenance() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        assets = root / "assets"
        assets.mkdir()
        payloads = {
            "cmux-tui-aarch64-apple-darwin": b"arm",
            "cmux-tui-app-host-aarch64-apple-darwin": b"host",
            "cmux-tui-x86_64-unknown-linux-musl": b"linux",
            "cmux-tui-dsyms-aarch64-apple-darwin": b"debug",
        }
        for name, payload in payloads.items():
            (assets / name).write_bytes(payload)
        output = root / "manifest.json"
        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--commit", "a" * 40,
                "--directory", str(assets),
                "--commit-time", "2026-10-27T05:00:00+00:00",
                "--server-url", "https://github.com",
                "--repository", "manaflow-ai/cmux",
                "--run-id", "123",
                "--output", str(output),
            ],
            check=True,
        )
        document = json.loads(output.read_text())
        assert document["commit"] == "a" * 40
        assert document["sourceCommit"] == "a" * 40
        assert document["attestationUrl"].endswith("/actions/runs/123")
        assert set(document["binaries"]) == {
            "cmux-tui-aarch64-apple-darwin",
            "cmux-tui-app-host-aarch64-apple-darwin",
            "cmux-tui-x86_64-unknown-linux-musl",
        }
        assert document["binaries"]["cmux-tui-aarch64-apple-darwin"] == hashlib.sha256(b"arm").hexdigest()
        assert document["runtimeByBinary"]["cmux-tui-aarch64-apple-darwin"]["os"] == "macos"


if __name__ == "__main__":
    test_manifest_records_every_staged_binary_and_provenance()
    print("PASS: fast commit manifest")
