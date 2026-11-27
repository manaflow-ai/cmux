#!/usr/bin/env python3
"""scripts/ci/cmux_tui_tree_key.py takes the `key` verb its callers pass (cmux-machine-channel.yml's plan,
cmux_machine_channel_pr_head.py): `key --version v2 REV` prints the same key as `--version v2 REV`.

Before, `key` was a usage error, every caller read an empty key, and the pull request head plan built the
machine channel on every land-tier head whatever it changed."""

from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cmux_tui_tree_key.py"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=ROOT, capture_output=True, text=True, timeout=120)


class TreeKeyVerb(unittest.TestCase):
    def test_key_verb_matches_bare_form(self):
        bare = run("--version", "v2", "HEAD")
        verb = run("key", "--version", "v2", "HEAD")
        self.assertEqual(bare.returncode, 0, bare.stderr)
        self.assertEqual(verb.returncode, 0, verb.stderr)
        self.assertRegex(verb.stdout.strip(), r"^[0-9a-f]{40}$")
        self.assertEqual(verb.stdout, bare.stdout)

    def test_key_verb_without_version(self):
        self.assertEqual(run("key", "HEAD").stdout, run("HEAD").stdout)

    def test_every_caller_form_is_accepted(self):
        # The argument shapes the callers use, read from their source, so a new caller shape is checked too.
        callers = [ROOT / ".github/workflows/cmux-machine-channel.yml", ROOT / "scripts/ci/cmux_machine_channel_pr_head.py"]
        for path in callers:
            text = path.read_text(encoding="utf-8")
            self.assertTrue(re.search(r'\bkey\b"?,? "?--version"?,? "?v2', text), f"{path} no longer passes `key --version v2`")
        self.assertEqual(run("key", "--version", "v2", "HEAD^{commit}").returncode, 0)

    def test_extra_arguments_still_refused(self):
        self.assertEqual(run("key", "HEAD", "HEAD").returncode, 2)


if __name__ == "__main__":
    unittest.main()
