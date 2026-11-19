"""Regression: XCTest succeeds but console export is empty; use retained samples."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "ios_launch_samples.py"
spec = importlib.util.spec_from_file_location("samples", SCRIPT)
samples = importlib.util.module_from_spec(spec)
spec.loader.exec_module(samples)


def line(flow="chat", phase="warm", **values):
    return "LAUNCHTTI " + json.dumps(dict(flow=flow, phase=phase, list_ms=10, open_ms=2, tti_ms=12, **values)) + "\n"


class SamplesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.out = Path(self.temp.name)
        (self.out / "ui-console.txt").touch()

    def attach(self, prefix, text):
        folder = self.out / (prefix + "-attachments")
        folder.mkdir(parents=True, exist_ok=True)
        # xcresulttool may use a UUID instead of the attachment's display name.
        (folder / "arbitrary-uuid.txt").write_text(text)

    def run_collector(self, *suites):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.out), "--suites", *suites], capture_output=True, text=True)

    def test_suite_summary_survives_empty_arrays_under_nounset(self):
        # Execute the runner's actual statement: a crash here prevents evidence.zip.
        runner = SCRIPT.with_name("cmux-next-ios-sim.sh").read_text()
        summary = next(row for row in runner.splitlines() if 'note "- UI tests ' in row)
        bash = os.environ.get("CMUX_TEST_BASH", "bash")
        for warm, cold in ((False, False), (True, False), (False, True), (True, True)):
            with self.subTest(warm=warm, cold=cold):
                setup = '''set -euo pipefail
note() { printf '%s\\n' "$1"; }
out=$1
ui_status=0 ui_action=test ui_seconds=1 t0=$SECONDS
ui_suites=() ui_cold=()
'''
                if warm:
                    setup += 'ui_suites=("LaunchTTIUITests/testChatOpenWarm")\n'
                if cold:
                    setup += 'ui_cold=("LaunchTTIColdUITests/testChatOpenCold")\n'
                result = subprocess.run([bash, "-c", setup + summary, "summary", str(self.out)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("exit 0", result.stdout)
                self.assertEqual("LaunchTTIUITests/testChatOpenWarm" in result.stdout, warm)
                self.assertEqual("LaunchTTIColdUITests/testChatOpenCold" in result.stdout, cold)

    def test_empty_console_uses_attachments_without_double_counting(self):
        self.attach("ui", line() * 10)
        (self.out / "ui-console.txt").write_text(line() * 10)
        result = self.run_collector("-only-testing:CmuxMobileAppUITests/LaunchTTIUITests/testChatOpenWarm")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.out / "launch-tti.jsonl").read_text().splitlines()), 10)
        (self.out / "ui-console.txt").write_text("")
        self.assertEqual(len(samples.collect(self.out)), 10)

    def test_cold_bundles_and_legacy_stdout(self):
        (self.out / "ui-console.txt").write_text(line() * 10)
        for n in range(10):
            self.attach(f"ui-cold/testTerminalInputCold-{n}", line("terminal", "cold", echo_ms=0))
            (self.out / f"ui-cold/testTerminalInputCold-{n}-console.txt").touch()
        result = self.run_collector("LaunchTTIUITests/testChatOpenWarm", "LaunchTTIColdUITests/testTerminalInputCold")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(samples.collect(self.out)), 20)

    def test_missing_or_partial_samples_fail(self):
        for n in (0, 9):
            with self.subTest(n=n):
                (self.out / "ui-console.txt").write_text(line() * n)
                result = self.run_collector("LaunchTTIUITests/testChatOpenWarm")
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"expected 10 samples, got {n}", (self.out / "launch-tti-error.txt").read_text())

    def test_invalid_measurement_fails(self):
        self.attach("ui", line("terminal", echo_ms=float("nan")))
        result = self.run_collector("LaunchTTIUITests")
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid echo_ms", result.stderr)

    def test_other_ui_suites_need_no_launch_samples(self):
        result = self.run_collector("SomeOtherUITests")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_suite_counts_and_skipped_inherited_methods(self):
        self.assertEqual(samples.expected_counts(["LaunchTTIUITests", "LaunchTTIColdUITests"], 3),
                         {("chat", "warm"): 10, ("terminal", "warm"): 10, ("chat", "cold"): 3, ("terminal", "cold"): 3})
        self.assertEqual(samples.expected_counts(["LaunchTTIColdUITests/testChatOpenWarm"], 3), {})


if __name__ == "__main__":
    unittest.main()
