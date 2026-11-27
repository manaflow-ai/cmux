#!/usr/bin/env python3
"""Verify and install the run-scoped cas-replay producer artifact."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
from typing import NoReturn


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message: str) -> NoReturn:
    raise SystemExit(f"cas-replay artifact: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact_dir", type=Path)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--install-to", type=Path, required=True)
    args = parser.parse_args()

    artifact_dir = args.artifact_dir
    manifest_path = artifact_dir / "manifest.json"
    binary = artifact_dir / "cas-replay"
    if not manifest_path.is_file() or not binary.is_file():
        fail("missing cas-replay or manifest.json")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"invalid manifest: {exc}")
    if manifest.get("schema_version") != 1:
        fail("unsupported manifest schema")
    if manifest.get("source_sha") != args.source_sha:
        fail(f"source SHA mismatch ({manifest.get('source_sha')!r} != {args.source_sha!r})")
    for key, value in (("runner_os", os.environ.get("RUNNER_OS")), ("runner_arch", os.environ.get("RUNNER_ARCH"))):
        if not value or manifest.get(key) != value:
            fail(f"{key} mismatch ({manifest.get(key)!r} != {value!r})")
    if not args.toolchain.is_file():
        fail(f"toolchain file is missing: {args.toolchain}")
    if manifest.get("rust_toolchain_sha256") != sha256(args.toolchain):
        fail("Rust toolchain digest mismatch")
    if manifest.get("binary_sha256") != sha256(binary):
        fail("binary digest mismatch")
    args.install_to.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, args.install_to)
    args.install_to.chmod(args.install_to.stat().st_mode | 0o111)


if __name__ == "__main__":
    main()
