"""scripts/ci/cmux-tui-rust-check.sh's `junit_tool tap`: a nextest `--profile ci` JUnit file printed as the TAP rows
scripts/ci/test_reds.py reads (exported_observations), so HQ's tap_flakes scores the cmux-tui workspace's flips."""
import importlib.util
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cmux-tui-rust-check.sh"
spec = importlib.util.spec_from_file_location("test_reds", ROOT / "scripts/ci/test_reds.py")
test_reds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(test_reds)

JUNIT = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="nextest-run" tests="3" failures="1" errors="0">
<testsuite name="cmux-tui-core::lib" tests="3" failures="1">
<testcase name="hub::keeps_order" classname="cmux-tui-core::lib" time="0.1"/>
<testcase name="hub::caps" classname="cmux-tui-core::lib" time="0.2"><failure message="thread 'hub::caps' panicked at src/hub.rs:10:5:&#10;assertion failed" type="test failure">output</failure></testcase>
<testcase name="hub::ignored" classname="cmux-tui-core::lib" time="0"><skipped/></testcase>
</testsuite>
</testsuites>
"""


def junit_tool() -> str:
    """The script's junit_tool function, alone: the rest of the script runs cargo."""
    found = re.search(r"^junit_tool\(\) \{.*?^\}$", SCRIPT.read_text(), re.S | re.M)
    assert found, "junit_tool is gone from cmux-tui-rust-check.sh"
    return found.group(0)


class Tap(unittest.TestCase):
    def test_every_ran_test_is_a_row_the_flake_reader_takes(self):
        with tempfile.TemporaryDirectory() as tmp:
            junit = Path(tmp) / "junit.xml"
            junit.write_text(JUNIT)
            out = subprocess.run(["bash", "-c", junit_tool() + '\njunit_tool tap "$1"', "-", str(junit)],
                                 check=True, capture_output=True, text=True).stdout
        self.assertEqual(test_reds.observations(out), [
            {"test": "cmux-tui-core::lib > hub::caps", "outcome": "fail",
             "signature": "thread 'hub::caps' panicked at src/hub.rs:10:5:"},
            {"test": "cmux-tui-core::lib > hub::keeps_order", "outcome": "pass", "signature": ""},
        ])

    def test_the_full_run_prints_the_rows(self):
        text = SCRIPT.read_text()
        self.assertIn('junit_tool tap "$junit_full"', text)
        self.assertIn('TAP_CI_ENABLED:-1', text)


if __name__ == "__main__":
    unittest.main()
