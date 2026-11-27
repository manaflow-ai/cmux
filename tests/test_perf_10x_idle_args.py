#!/usr/bin/env python3
"""perf-10x-idle.sh's argument parsing: adblock=off is accepted and launches with the built-in ad blocker off.

The CI controller refuses JSON in a step argument, so settings={...} cannot carry the idle A/B that splits the
built-in uBlock Origin's first-launch writes from the app's own (goal idle-gpu-disk); adblock=off is that A/B.
"""
import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/measure/perf-10x-idle.sh"


class Args(unittest.TestCase):
    def run_args(self, *args):
        # The argument loop runs before any work: an unknown argument after adblock=off exits 2 naming only itself,
        # so adblock=off parsed.
        return subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True, timeout=30)

    def test_adblock_off_is_a_known_argument(self):
        done = self.run_args("adblock=off", "not-an-arg=1")
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("unknown argument not-an-arg=1", done.stderr)
        self.assertNotIn("adblock=off", done.stderr)

    def test_adblock_other_values_are_refused(self):
        done = self.run_args("adblock=on")
        self.assertEqual(done.returncode, 2)
        self.assertIn("unknown argument adblock=on", done.stderr)

    def test_adblock_off_config_turns_the_built_in_blocker_off(self):
        line = next(l for l in SCRIPT.read_text().splitlines() if l.strip().startswith("adblock=off)"))
        config = json.loads(re.search(r"--config '([^']+)'", line).group(1))
        self.assertEqual(config, {"browser": {"builtInAdBlocker": False}})


if __name__ == "__main__":
    unittest.main()
