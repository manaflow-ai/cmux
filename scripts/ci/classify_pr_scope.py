#!/usr/bin/env python3
"""Classify pull request scope for workflow routing."""

from __future__ import annotations

import argparse
import fnmatch
import subprocess
import sys
from pathlib import Path, PurePosixPath


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
DEFAULT_PATTERNS_FILE = REPO_ROOT / ".github/ci/docs-only-paths.txt"


def load_patterns(patterns_file: Path) -> list[str]:
    patterns: list[str] = []
    for raw_line in patterns_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        patterns.append(line)
    if not patterns:
        raise ValueError(f"No patterns found in {patterns_file}")
    return patterns


def normalize_path(raw_path: str) -> str:
    return raw_path.strip().replace("\\", "/").lstrip("./")


def matches_any(path: str, patterns: list[str]) -> bool:
    pure_path = PurePosixPath(path)
    return any(pure_path.match(pattern) or fnmatch.fnmatch(path, pattern) for pattern in patterns)


def changed_paths(repo_root: Path, base: str, head: str) -> list[str]:
    proc = subprocess.run(
        ["git", "-C", str(repo_root), "diff", "--name-only", "--diff-filter=ACMR", f"{base}...{head}"],
        check=True,
        capture_output=True,
        text=True,
    )
    return [normalize_path(line) for line in proc.stdout.splitlines() if normalize_path(line)]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-name", required=True, help="GitHub event name")
    parser.add_argument("--repo-root", default=str(REPO_ROOT), help="Repository root for git diff mode")
    parser.add_argument("--patterns-file", default=str(DEFAULT_PATTERNS_FILE), help="Path matcher config")
    parser.add_argument("--base", help="Base git ref/SHA for diff mode")
    parser.add_argument("--head", help="Head git ref/SHA for diff mode")
    parser.add_argument("--path", action="append", default=[], help="Changed path for direct classification tests")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    patterns_file = Path(args.patterns_file)
    patterns = load_patterns(patterns_file)

    if args.path:
        paths = [normalize_path(path) for path in args.path if normalize_path(path)]
    elif args.event_name != "pull_request":
        paths = []
    else:
        if not args.base or not args.head:
            raise ValueError("--base and --head are required for pull_request diff mode")
        paths = changed_paths(Path(args.repo_root), args.base, args.head)

    docs_only = bool(paths) and all(matches_any(path, patterns) for path in paths)
    run_heavy_macos = args.event_name != "pull_request" or not docs_only

    print(f"docs_only={'true' if docs_only else 'false'}")
    print(f"run_heavy_macos={'true' if run_heavy_macos else 'false'}")

    if paths:
        print(f"changed_path_count={len(paths)}")
    else:
        print("changed_path_count=0")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"error={exc}", file=sys.stderr)
        raise
