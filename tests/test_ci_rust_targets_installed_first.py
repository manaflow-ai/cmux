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
# `rustup target add`, with any flags or a `+toolchain` between the words.
SHELL_ADD = re.compile(r"\brustup(?:\s+(?:\+|-)\S*)*\s+target(?:\s+-\S*)*\s+add\b")
# A command string that starts with it: `bash -c "rustup target add x"`.
STRING_ADD = re.compile(r"^\s*(?:\S*/)?" + SHELL_ADD.pattern.removeprefix(r"\b"))
# The same as a Python or JavaScript argv list: "rustup", "target", "add", flags allowed between.
ARGV_ADD = re.compile(r"[\"'](?:\S*/)?rustup[\"']\s*,\s*(?:[\"'][+-][^\"']*[\"']\s*,\s*)*[\"']target[\"']\s*,\s*"
                      r"(?:[\"']-[^\"']*[\"']\s*,\s*)*[\"']add[\"']")
QUOTED = re.compile(r"\"((?:\\.|[^\"\\])*)\"|'([^']*)'")


def tracked_scripts() -> list[str]:
    names = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "scripts"], check=True,
                           capture_output=True, text=True).stdout.split("\0")
    return sorted(name for name in names if name.endswith(SCRIPT_SUFFIXES) and name != HELPER)


def logical_lines(text: str) -> list[tuple[int, str]]:
    """(first line number, text) with backslash-continued lines joined."""
    joined: list[tuple[int, str]] = []
    pending: tuple[int, str] | None = None
    for number, line in enumerate(text.splitlines(), start=1):
        if pending is not None:
            number, line = pending[0], pending[1] + " " + line.lstrip()
        if line.endswith("\\"):
            pending = (number, line[:-1])
            continue
        pending = None
        joined.append((number, line))
    if pending is not None:
        joined.append(pending)
    return joined


def unguarded_target_adds(text: str) -> list[int]:
    """Line numbers in TEXT that run `rustup target add` directly.

    A quoted single word ("rustup") is a command word, so its quotes are dropped. A quoted phrase is
    prose (an error message telling a person what to run) unless it starts with the command itself.
    """
    found = []
    for number, line in logical_lines(text):
        code = line.lstrip()
        if code.startswith(("#", "//")):
            continue
        if ARGV_ADD.search(code):
            found.append(number)
            continue
        phrases: list[str] = []

        def unquote(match: re.Match[str]) -> str:
            body = match.group(1) if match.group(1) is not None else match.group(2)
            if re.search(r"\s", body):
                phrases.append(body)
                return " _ "
            return body

        bare = QUOTED.sub(unquote, code)
        if SHELL_ADD.search(bare) or any(STRING_ADD.search(phrase) for phrase in phrases):
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
            'subprocess.run(["rustup", "+1.95.0", "target", "add", t])',
            '"rustup" target add x86_64-apple-darwin',
            'rustup --verbose target add x86_64-apple-darwin',
            '/usr/local/bin/rustup target add x86_64-apple-darwin',
            'bash -c "rustup target add x86_64-apple-darwin"',
            'rustup \\\n  target add \\\n  x86_64-apple-darwin',
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
