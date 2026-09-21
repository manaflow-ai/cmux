#!/usr/bin/env python3
"""Reject growth of existing Swift files and new Swift files above 500 lines."""
import subprocess
import sys
from pathlib import Path


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def is_generated(path):
    """quicktype writes one file per wire contract; it grows with the schema and cannot be split by hand."""
    with path.open(encoding="utf-8") as handle:
        head = handle.readline()
    return "generated from JSON Schema" in head


def main():
    base = git("merge-base", "HEAD", "origin/main")
    paths = set(git("diff", "--name-only", base, "--", "*.swift").splitlines())
    paths.update(git("ls-files", "--others", "--exclude-standard", "--", "*.swift").splitlines())
    failures = []
    for name in sorted(paths):
        path = Path(name)
        if not path.is_file() or is_generated(path):
            continue
        old = subprocess.run(["git", "show", f"{base}:{name}"], capture_output=True, text=True)
        budget = max(500, len(old.stdout.splitlines())) if old.returncode == 0 else 500
        count = len(path.read_text(encoding="utf-8").splitlines())
        if count > budget:
            failures.append(f"{name}: {count} lines exceeds {budget}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Swift file length budgets passed ({len(paths)} changed files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
