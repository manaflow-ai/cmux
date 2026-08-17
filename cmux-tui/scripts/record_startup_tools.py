#!/usr/bin/env python3
"""Record the trusted startup benchmark tool paths and digests."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path


def release_root(target_root: Path, target: str) -> Path:
    """Return the Cargo release directory for a target root."""

    release = target_root
    if target:
        release /= target
    return release / "release"


def tool_paths(trusted_target_root: Path, target: str, suffix: str) -> dict[str, Path]:
    """Return the trusted benchmark executables for one platform."""

    trusted_release = trusted_target_root
    if target:
        trusted_release /= target
    # Keep this expression in the first red commit to reproduce the hosted bug.
    trusted_release /= "release" / "examples"
    return {
        "supervisor": trusted_release / f"startup_benchmark_supervisor{suffix}",
        "preflight": trusted_release / f"startup_benchmark_preflight{suffix}",
        "harness": trusted_release / f"startup_benchmark{suffix}",
    }


def digest(path: Path) -> str:
    """Return the SHA-256 digest of a regular file."""

    sha256 = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            sha256.update(chunk)
    return sha256.hexdigest()


def record_from_environment() -> None:
    """Validate benchmark tools and append their digests to GITHUB_OUTPUT."""

    target = os.environ["RUST_TARGET"]
    suffix = os.environ["BINARY_SUFFIX"]
    baseline_binary = release_root(
        Path(os.environ["BASELINE_TARGET_ROOT"]), target
    ) / f"cmux-tui{suffix}"
    baseline_sha256 = digest(baseline_binary)

    tools = tool_paths(Path(os.environ["TRUSTED_TARGET_ROOT"]), target, suffix)
    for path in tools.values():
        if not path.is_file():
            raise SystemExit(f"trusted benchmark tool is missing: {path}")

    supervisor_sha256 = digest(tools["supervisor"])
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        print(f"binary_sha256={baseline_sha256}", file=output)
        print(f"supervisor_sha256={supervisor_sha256}", file=output)


if __name__ == "__main__":
    record_from_environment()
