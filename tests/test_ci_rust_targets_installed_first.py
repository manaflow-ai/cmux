#!/usr/bin/env python3
"""Build scripts add a Rust target only when it is missing.

`rustup target add` syncs the channel manifest from static.rust-lang.org on
every call, even when the toolchain and the target's rust-std are already
installed. A build step on a fleet machine with everything on disk failed on
exactly that: "info: syncing channel updates for 1.95.0-aarch64-apple-darwin /
error: could not download file from
'https://static.rust-lang.org/dist/channel-rust-1.95.0.toml' ... Operation timed
out". scripts/lib/rust-targets.sh's ensure_rust_targets reads
`rustup target list --installed` first, adds only the missing targets, and
retries the add a bounded number of times.

This guard fails when a tracked script under scripts/ runs `rustup target add`
itself instead of calling ensure_rust_targets. Comments and quoted text (an
error message that tells a person what to run) do not count.

Usage: python3 tests/test_ci_rust_targets_installed_first.py
"""
from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = "scripts/lib/rust-targets.sh"
SCRIPT_SUFFIXES = (".sh", ".bash", ".py", ".mjs", ".js", ".ts")
# `rustup target add` or `rustup +1.95.0 target add` on a command line.
SHELL_ADD = re.compile(r"\brustup\s+(?:\+\S+\s+)?target\s+add\b")
# The same as a Python or JavaScript argv list: "rustup", "target", "add".
ARGV_ADD = re.compile(r"[\"']rustup[\"']\s*,\s*(?:[\"']\+[^\"']*[\"']\s*,\s*)?[\"']target[\"']\s*,\s*[\"']add[\"']")
QUOTED = re.compile(r"\"(?:\\.|[^\"\\])*\"|'[^']*'")


def tracked_scripts() -> list[str]:
    names = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "scripts"], check=True,
                           capture_output=True, text=True).stdout.split("\0")
    return sorted(name for name in names if name.endswith(SCRIPT_SUFFIXES) and name != HELPER)


def unguarded_target_adds(text: str) -> list[int]:
    """1-based line numbers in TEXT that run `rustup target add` directly."""
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        code = line.lstrip()
        if code.startswith(("#", "//")):
            continue
        if SHELL_ADD.search(QUOTED.sub("", code)) or ARGV_ADD.search(code):
            found.append(number)
    return found


class RustTargetsInstalledFirst(unittest.TestCase):
    def test_scripts_use_the_helper(self) -> None:
        offenders = []
        for name in tracked_scripts():
            try:
                text = (ROOT / name).read_text(encoding="utf-8")
            except (OSError, UnicodeError):
                continue
            offenders += [f"{name}:{line}" for line in unguarded_target_adds(text)]
        self.assertEqual(
            offenders, [],
            "these scripts run `rustup target add` directly, which reaches static.rust-lang.org even when "
            f"the target is installed; source {HELPER} and call ensure_rust_targets instead",
        )

    def test_the_helper_exists_and_reads_the_installed_list(self) -> None:
        text = (ROOT / HELPER).read_text(encoding="utf-8")
        self.assertIn("ensure_rust_targets()", text)
        self.assertIn("--installed", text)

    def test_detection(self) -> None:
        flagged = [
            'rustup target add aarch64-apple-darwin',
            '(cd "$dir" && rustup target add "${targets[@]}")',
            'rustup +1.95.0 target add x86_64-apple-darwin',
            '  rustup target add --toolchain "$t" "$x" >/dev/null',
            'subprocess.run(["rustup", "target", "add", target], check=True)',
        ]
        allowed = [
            '# rustup target add aarch64-apple-darwin',
            'die "no compiler_builtins rlib for $target (rustup target add $target)"',
            "echo 'run: rustup target add x86_64-apple-darwin'",
            'ensure_rust_targets aarch64-apple-darwin',
            'rustup target list --installed',
        ]
        for line in flagged:
            with self.subTest(line=line):
                self.assertEqual(unguarded_target_adds(line), [1])
        for line in allowed:
            with self.subTest(line=line):
                self.assertEqual(unguarded_target_adds(line), [])


if __name__ == "__main__":
    unittest.main()
