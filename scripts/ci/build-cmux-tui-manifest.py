#!/usr/bin/env python3
"""Build the commit-addressed cmux-tui manifest from staged binaries."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime
from pathlib import Path


def runtime_for(name: str) -> dict[str, str]:
    target = name
    for prefix in (
        "cmux-tui-",
        "hook-",
        "acpmux-",
        "app-host-",
        "cloud-server-",
        "browser-host-",
        "holder-",
        "host-",
        "agent-screen-detection-",
    ):
        target = target.removeprefix(prefix)
    target = target.removesuffix(".exe")
    if "apple-darwin" in target:
        return {"os": "macos", "architecture": "arm64" if target.startswith("aarch64") else "x86_64", "libc": "none"}
    if "windows" in target:
        return {"os": "windows", "architecture": "x86_64", "libc": "none"}
    return {"os": "linux", "architecture": "arm64" if target.startswith("aarch64") else "x86_64", "libc": "musl"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--commit", required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--commit-time", required=True)
    parser.add_argument("--server-url", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    directory = args.directory
    files = sorted(
        path for path in directory.glob("cmux-tui-*")
        if path.is_file()
        and not path.name.startswith("cmux-tui-dsyms-")
        and not path.name.endswith((".txt", ".sha256"))
    )
    if not files:
        raise SystemExit("no cmux-tui binaries were staged")
    source_repository = f"{args.server_url.rstrip('/')}/{args.repository}"
    manifest = {
        "commit": args.commit,
        "builtAt": datetime.fromisoformat(args.commit_time).isoformat(),
        "sourceRepository": source_repository,
        "sourceCommit": args.commit,
        "attestationUrl": f"{source_repository}/actions/runs/{args.run_id}",
        "releaseUrl": None,
        "license": "GPL-3.0-or-later",
        "runtimeByBinary": {path.name: runtime_for(path.name) for path in files},
        "binaries": {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in files
        },
    }
    args.output.write_text(json.dumps(manifest, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
