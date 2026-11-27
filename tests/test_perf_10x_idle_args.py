#!/usr/bin/env python3
"""perf-10x-idle.sh's argument parsing: adblock=off is accepted and launches with the built-in ad blocker off.

The CI controller refuses JSON in a step argument, so settings={...} cannot carry the idle A/B that splits the
built-in uBlock Origin's first-launch writes from the app's own (goal idle-gpu-disk); adblock=off is that A/B.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
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

    def settings(self, *args):
        done = self.run_args(*args, "print_settings=1")
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)

    def test_adblock_off_config_turns_the_built_in_blocker_off(self):
        self.assertEqual(self.settings("adblock=off"), {"browser": {"builtInAdBlocker": False}})

    def test_no_settings_launches_with_none(self):
        self.assertEqual(self.settings(), {})

    def test_adblock_off_merges_with_settings_in_either_order(self):
        want = {"browser": {"hibernation": 1, "builtInAdBlocker": False}, "appearance": {"x": 1}}
        given = 'settings={"browser":{"hibernation":1},"appearance":{"x":1}}'
        self.assertEqual(self.settings(given, "adblock=off"), want)
        self.assertEqual(self.settings("adblock=off", given), want)

    def test_settings_alone_pass_through(self):
        self.assertEqual(self.settings('settings={"browser":{"builtInAdBlocker":true}}'),
                         {"browser": {"builtInAdBlocker": True}})

class Report(unittest.TestCase):
    def report(self, samples):
        text = SCRIPT.read_text()
        start = text.index("python3 - \"$work/agents.json\" <<'PY'")
        body = text[text.index("\n", start) + 1:text.index("\nPY\n", start)]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "agents.json"
            path.write_text(json.dumps({"samples": samples}))
            done = subprocess.run([sys.executable, "-I", "-c", body, str(path)], capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        return [l for l in done.stdout.splitlines() if l.startswith("PERF-IDLE-WRITER ")]

    def test_writer_rows_name_each_writing_process_only(self):
        rows = self.report([{"label": "idle-10", "workspaces": 10, "kinds": {}, "processes": [
            {"pid": 7, "kind": "acpmux-daemon", "command": "acpmux daemon", "disk_write_mb_per_h": 7.3,
             "logical_write_mb_per_h": 21.1},
            {"pid": 8, "kind": "acpmux-daemon", "command": "acpmux host", "disk_write_mb_per_h": 0.0,
             "logical_write_mb_per_h": 0.05},
            {"pid": 9, "kind": "app", "command": "cmux"}]}])
        self.assertEqual(rows, ['PERF-IDLE-WRITER app-agents idle-10 kind=acpmux-daemon pid=7 disk_write_mb_per_h=7.3 '
                                'logical_write_mb_per_h=21.1 command="acpmux daemon"'])


if __name__ == "__main__":
    unittest.main()
