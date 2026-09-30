#!/usr/bin/env python3
"""Reject growth of existing Swift files and new Swift files above 500 lines."""
import subprocess
import sys
from pathlib import Path


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


GENERATED_CONTRACT_FILES = {
    # quicktype emits one monolithic Codable model file for this wire contract;
    # schema additions must change its generated line count atomically.
    Path("Packages/Shared/CmuxIrxTransport/Sources/CmuxIrxTransport/ControlPlane/V2WireModels.swift"),
}


def main():
    base = git("merge-base", "HEAD", "origin/main")
    # A moved file keeps the budget of its old path, so a rename is not
    # treated as a new file.
    previous = {}
    paths = set()
    for line in git("-c", "diff.renameLimit=0", "diff", "-M", "--name-status", base, "--", "*.swift").splitlines():
        fields = line.split("\t")
        if fields[0].startswith("R") and len(fields) == 3:
            previous[fields[2]] = fields[1]
        paths.add(fields[-1])
    paths.update(git("ls-files", "--others", "--exclude-standard", "--", "*.swift").splitlines())
    failures = []
    for name in sorted(paths):
        path = Path(name)
        if not path.is_file() or path in GENERATED_CONTRACT_FILES:
            continue
        old_name = previous.get(name, name)
        old = subprocess.run(["git", "show", f"{base}:{old_name}"], capture_output=True, text=True)
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
