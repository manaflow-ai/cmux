#!/usr/bin/env python3
"""Route browser-engine changes to the mandatory hosted runtime test."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterable

from verify_browser_runtime_artifact import is_browser_engine_path


def changed_files(base_sha: str, head_sha: str) -> list[str]:
    merge_base = subprocess.check_output(
        ["git", "merge-base", base_sha, head_sha], text=True
    ).strip()
    output = subprocess.check_output(
        ["git", "diff", "--name-only", merge_base, head_sha], text=True
    )
    return [line for line in output.splitlines() if line.strip()]


def browser_engine_changed(paths: Iterable[str]) -> bool:
    return any(is_browser_engine_path(path) for path in paths)


def write_output(value: bool, output_path: str | None) -> None:
    if output_path:
        with Path(output_path).open("a", encoding="utf-8") as handle:
            handle.write(f"browser_engine={str(value).lower()}\n")


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    parser.add_argument("--base-sha", default="")
    parser.add_argument("--head-sha", default="")
    parser.add_argument("--files-from", type=Path)
    parser.add_argument(
        "--github-output",
        default=os.environ.get("GITHUB_OUTPUT"),
    )
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if args.event_name != "pull_request":
        write_output(True, args.github_output)
        print("Non-PR event; running browser runtime verification.")
        return 0

    try:
        if args.files_from:
            paths = args.files_from.read_text(encoding="utf-8").splitlines()
        elif args.base_sha and args.head_sha:
            paths = changed_files(args.base_sha, args.head_sha)
        else:
            raise RuntimeError("pull_request event is missing changed-file inputs")
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        # An unknown diff is unsafe to classify as cheap. Fail open to the
        # expensive browser lane so a routing failure cannot hide a runtime
        # change.
        print(f"Could not classify browser changes; running the gate: {error}", file=sys.stderr)
        write_output(True, args.github_output)
        return 0

    required = browser_engine_changed(paths) if paths else True
    write_output(required, args.github_output)
    print(f"Browser runtime verification required: {str(required).lower()}")
    if required:
        print("Browser-engine paths:")
        for path in paths:
            if is_browser_engine_path(path):
                print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
