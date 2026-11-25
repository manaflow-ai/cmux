#!/usr/bin/env python3
"""The crash-class rules (cmux-next-crash-class.yml) as a cmux-next fast gate: red only for what the PR adds.

Usage: crash_class_fast_gate.py --base BASE_DIR
Run in the merge checkout (HEAD: the pull request merged into BASE, BASE its first parent);
BASE_DIR is BASE's exported tree (cmux_next_fast_gates.py's export_tree: Packages,
cmux-tui/crates, scripts/cmux-next).

- concurrency:  scripts/ci/crash-class-gate.sh --pr. It already fails only for findings in files the
                pull request changes, or for a change to its rules (scripts/ci/pr_owned_findings.py).
- selectors:    scripts/cmux-next/check-objc-selectors.py (unrecognized selectors from `super` calls)
- CEF contract: scripts/cmux-next/check-cef-objc-contract.py (selectors Chromium sends to NSApp)
                These two check the whole tree. Each runs on the merge; when it fails there, the
                merge's copy runs again with --root BASE_DIR, and only the failures the merge adds
                fail the gate. A failure is keyed by its text without line numbers, so code that
                moved is not new, and a second copy of a base failure is.

Every check runs even after one fails. A check that ends with neither its ok exit nor a failure
line (a traceback) is red: nothing can be compared. Exit 0 = green, 1 = red.
"""
from __future__ import annotations

import argparse
import collections
import re
import subprocess
import sys
from pathlib import Path

CONCURRENCY = "scripts/ci/crash-class-gate.sh"
# (name, script, the prefix of its failure lines)
WHOLE_TREE = (
    ("selectors", "scripts/cmux-next/check-objc-selectors.py", "objc-selectors: "),
    ("CEF contract", "scripts/cmux-next/check-cef-objc-contract.py", "cef-objc-contract: "),
)
LINE_NUMBER = re.compile(r":\d+:")


def run_check(script: str, prefix: str, root: Path) -> tuple[str, collections.Counter, str]:
    """("green" | "red" | "failed", failures keyed without line numbers, output)."""
    done = subprocess.run([sys.executable, "-I", script, "--root", str(root)], capture_output=True, text=True)
    text = done.stdout + done.stderr
    found = collections.Counter(LINE_NUMBER.sub(":", line[len(prefix):].strip())
                                for line in text.splitlines() if line.startswith(prefix))
    if done.returncode == 0 and not found:
        return "green", found, text
    return ("red" if found and done.returncode == 1 else "failed"), found, text


def whole_tree(name: str, script: str, prefix: str, base: Path) -> bool:
    """Whether the merge adds no failure of this check over BASE."""
    state, merge, text = run_check(script, prefix, Path.cwd())
    if state == "green":
        print(f"crash-class rules ({name}): ok on the merge")
        return True
    if state == "failed":
        print(text)
        print(f"::error::crash-class rules ({name}): {script} did not run on the merge (no ok exit and no "
              "failure line)")
        return False
    base_state, on_base, base_text = run_check(script, prefix, base)
    if base_state == "failed":
        print(text)
        print(base_text)
        print(f"::error::crash-class rules ({name}): {script} failed on the merge and did not run on the base, "
              "so its failures cannot be compared")
        return False
    added = merge - on_base
    if not added:
        print(f"::warning::crash-class rules ({name}): {sum(merge.values())} failure(s), all already on the base; "
              "this change adds none")
        return True
    for failure in sorted(added):
        print(f"::error::crash-class rules ({name}): the merge adds: {failure}")
    return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, type=Path, help="BASE's exported tree")
    base = parser.parse_args(argv).base.resolve()
    ok = subprocess.run(["bash", CONCURRENCY, "--pr"]).returncode == 0
    print(f"crash-class rules (concurrency): {'ok' if ok else 'red for files this change touches'}")
    for name, script, prefix in WHOLE_TREE:
        ok = whole_tree(name, script, prefix, base) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
