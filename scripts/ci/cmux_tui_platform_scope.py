#!/usr/bin/env python3
"""Select the hosted cmux-tui platforms needed for a focused commit."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


MACOS_PATH_MARKERS = (
    "/darwin/",
    "/darwin.",
    "/macos/",
    "/macos.",
    "/pty/",
    "/pty.",
    "chatmux-relay/",
    "Cargo.lock",
    "Cargo.toml",
    "rust-toolchain",
)
MACOS_DIFF = re.compile(r"(?:target_os\s*=\s*[\"']macos|cfg[^\n]*darwin|cfg[^\n]*pty)")


def changed_paths(repo: Path, base: str, head: str) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(repo), "diff", "--name-only", "--diff-filter=ACMRTUXB", base, head],
        check=True,
        capture_output=True,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def path_requires_macos(path: str) -> bool:
    normalized = f"/{path.lower()}"
    return any(marker.lower() in normalized for marker in MACOS_PATH_MARKERS)


def diff_requires_macos(repo: Path, base: str, head: str, path: str) -> bool:
    if path_requires_macos(path) or not path.endswith((".rs", ".toml")):
        return path_requires_macos(path)
    result = subprocess.run(
        ["git", "-C", str(repo), "diff", "--unified=0", base, head, "--", path],
        check=True,
        capture_output=True,
        text=True,
    )
    return any(
        line[:1] in {"+", "-"} and not line.startswith(("+++", "---")) and MACOS_DIFF.search(line)
        for line in result.stdout.splitlines()
    )


def scope(repo: Path, base: str, head: str) -> dict[str, object]:
    paths = changed_paths(repo, base, head)
    macos_paths = [path for path in paths if diff_requires_macos(repo, base, head, path)]
    return {
        "macos_required": bool(macos_paths),
        "macos_paths": macos_paths,
        "os": ["linux", "macos"] if macos_paths else ["linux"],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    args = parser.parse_args()
    print(json.dumps(scope(args.repo, args.base, args.head), separators=(",", ":")))


if __name__ == "__main__":
    main()
