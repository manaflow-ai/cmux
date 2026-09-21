#!/usr/bin/env python3
"""Extract validated typed test-result JSON from one app-host xcresult bundle."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys


COMMANDS = {
    "summary": ["get", "test-results", "summary"],
    "tests": ["get", "test-results", "tests"],
}


def extract(bundle: Path) -> tuple[bool, list[str]]:
    stem = bundle.with_suffix("")
    failures: list[str] = []

    for kind, subcommand in COMMANDS.items():
        output = Path(f"{stem}.{kind}.json")
        temporary = Path(f"{output}.tmp")
        error = Path(f"{stem}.{kind}.err")
        output.unlink(missing_ok=True)
        temporary.unlink(missing_ok=True)
        error.unlink(missing_ok=True)

        with temporary.open("wb") as stdout, error.open("wb") as stderr:
            completed = subprocess.run(
                ["xcrun", "xcresulttool", *subcommand, "--path", str(bundle), "--compact"],
                stdout=stdout,
                stderr=stderr,
                check=False,
            )

        if completed.returncode != 0:
            temporary.unlink(missing_ok=True)
            failures.append(f"{kind}: xcresulttool exited {completed.returncode}")
            continue

        try:
            with temporary.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
            if not isinstance(payload, dict):
                raise ValueError("top-level value is not an object")
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            with error.open("ab") as handle:
                handle.write(f"typed JSON validation failed: {exc}\n".encode())
            temporary.unlink(missing_ok=True)
            failures.append(f"{kind}: invalid JSON")
            continue

        os.replace(temporary, output)

    return not failures, failures


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <result.xcresult>", file=sys.stderr)
        return 2

    bundle = Path(sys.argv[1])
    if not bundle.is_dir():
        print(f"xcresult bundle not found: {bundle}", file=sys.stderr)
        return 2

    passed, failures = extract(bundle)
    if passed:
        print(f"Captured validated typed xcresult JSON for {bundle}")
        return 0

    print(
        "Typed xcresult extraction incomplete for "
        f"{bundle}: {'; '.join(failures)}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
