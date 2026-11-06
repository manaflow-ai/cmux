#!/usr/bin/env python3
"""No workflow or script passes a Sparkle private key to a process on its command line.

A process's arguments are readable by every other process on the machine (ps,
/proc/PID/cmdline), so the key reaches scripts/derive_sparkle_public_key.swift
on standard input (`printf '%s' "$KEY" | env -u KEY swift ... --stdin`;
printf is a shell builtin, so the key is never an argument), and the helper
refuses any other arguments. This test reads every workflow and shell script
and fails when a call to the helper passes anything but `--stdin`, or when a
line puts a `*SPARKLE_PRIVATE_KEY` variable on the command line of `swift`,
`sign_update` or `generate_appcast`. The Mac half (the helper really derives
the key from stdin and rejects an argument) is
tests/test_derive_sparkle_public_key.sh, run by signing-keychain-macos.yml.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = "derive_sparkle_public_key.swift"
# What follows the helper's name on its line: only `--stdin`, then the end of
# the command (a quote, `)`, `|`, `;`, `&` or the end of the line).
HELPER_CALL = re.compile(re.escape(HELPER) + r"""["']?(?P<rest>[^\n]*)""")
STDIN_ONLY = re.compile(r"""^\s+--stdin\s*(?:["')|;&]|$)""")
KEY_ON_ARGV = re.compile(r"""\b(?:swift|sign_update|generate_appcast)\b[^|;&\n]*\$\{?[A-Z_]*SPARKLE_PRIVATE_KEY\b""")


def sources() -> dict[str, str]:
    paths = sorted((ROOT / ".github/workflows").glob("*.y*ml")) + sorted((ROOT / "scripts").rglob("*.sh"))
    return {str(path.relative_to(ROOT)): path.read_text(errors="replace") for path in paths}


def violations(files: dict[str, str]) -> list[str]:
    problems = []
    for name, text in sorted(files.items()):
        for number, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for match in HELPER_CALL.finditer(line):
                # A path in a list (release-surface.txt, a workflow's paths:) is not a call.
                if "swift" not in line[:match.start()]:
                    continue
                if not STDIN_ONLY.match(match.group("rest")):
                    problems.append(f"{name}:{number}: {HELPER} takes the key on stdin with --stdin only: "
                                    f"{line.strip()}")
            if KEY_ON_ARGV.search(line):
                problems.append(f"{name}:{number}: a Sparkle private key is on a command line: {line.strip()}")
    return problems


class SelfTest(unittest.TestCase):
    def test_accepts_stdin_calls(self) -> None:
        files = {"ok.yml": "\n".join([
            "          signing_key=\"$(",
            "            printf '%s' \"$SPARKLE_PRIVATE_KEY\" |",
            "              env -u SPARKLE_PRIVATE_KEY swift scripts/derive_sparkle_public_key.swift --stdin",
            "          )\"",
            "      swift \"$scripts_dir/derive_sparkle_public_key.swift\" --stdin",
            "  # swift scripts/derive_sparkle_public_key.swift \"$SPARKLE_PRIVATE_KEY\"",
            "      - scripts/derive_sparkle_public_key.swift",
            "scripts/derive_sparkle_public_key.swift",
        ])}
        self.assertEqual(violations(files), [])

    def test_rejects_key_arguments(self) -> None:
        bad = [
            "SPARKLE_PUBLIC_KEY=\"$(swift scripts/derive_sparkle_public_key.swift \"$SPARKLE_PRIVATE_KEY\")\"",
            "key=$(swift scripts/derive_sparkle_public_key.swift $NIGHTLY_SPARKLE_PRIVATE_KEY)",
            "swift scripts/derive_sparkle_public_key.swift --stdin \"$SPARKLE_PRIVATE_KEY\"",
            "swift scripts/derive_sparkle_public_key.swift",
            "sign_update --ed-key \"${SPARKLE_PRIVATE_KEY}\" app.dmg",
        ]
        for line in bad:
            with self.subTest(line=line):
                self.assertNotEqual(violations({"bad.sh": line}), [])


def main() -> int:
    suite = unittest.TestLoader().loadTestsFromTestCase(SelfTest)
    if not unittest.TextTestRunner(stream=sys.stderr, verbosity=0).run(suite).wasSuccessful():
        return 1
    files = sources()
    problems = violations(files)
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    if problems:
        return 1
    calls = sum(len(HELPER_CALL.findall(text)) for text in files.values())
    print(f"PASS: no Sparkle private key on a command line ({calls} helper references in {len(files)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
