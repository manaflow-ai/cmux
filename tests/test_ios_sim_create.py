"""cmux-next-ios-sim.sh's sim_create: every simulator the step makes goes through it (hermetic).

On a build fleet worker that offers $CMUX_CI_SIM_CREATE (hq build-fleet/cmd/worker/sim_slim.go) the
worker makes the simulator, slim when the step declared its simulator features and the worker slims;
everywhere else it is the stock `simctl create` the step always ran.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/cmux-next-ios-sim.sh"

FAKE = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["CALLS"], "a") as f:
    f.write(json.dumps({"tool": os.path.basename(sys.argv[0]), "args": sys.argv[1:]}) + "\n")
print("AAAAAAAA-0000-0000-0000-000000000001")
'''


def sim_create_block():
    script = SCRIPT.read_text()
    start = script.index("# sim_create NAME DEVICE_TYPE RUNTIME [SET]")
    return script[start:script.index("# --- end sim_create", start)]


class SimCreateTests(unittest.TestCase):
    def run_create(self, *args, helper=True):
        tmp = tempfile.TemporaryDirectory(prefix="cmux-sim-create-")
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        binaries = root / "bin"
        binaries.mkdir()
        for name in ("xcrun", "cmux-ci-sim-create"):
            tool = binaries / name
            tool.write_text(FAKE)
            tool.chmod(0o755)
        calls = root / "calls.jsonl"
        harness = root / "create.sh"
        harness.write_text("set -euo pipefail\n" + sim_create_block() + '\nudid="$(sim_create "$@")"\necho "$udid"\n')
        env = {**os.environ, "PATH": f"{binaries}{os.pathsep}{os.environ['PATH']}", "CALLS": str(calls)}
        env.pop("CMUX_CI_SIM_CREATE", None)
        if helper:
            env["CMUX_CI_SIM_CREATE"] = str(binaries / "cmux-ci-sim-create")
        run = subprocess.run(["bash", str(harness), *args], env=env, text=True, capture_output=True, timeout=20)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout.strip(), "AAAAAAAA-0000-0000-0000-000000000001")
        return [json.loads(line) for line in calls.read_text().splitlines()]

    def test_the_worker_helper_makes_it_with_the_set(self):
        calls = self.run_create("cmux-next-ios-sim", "iPhone-17", "iOS-26-5", "/work/sims")
        self.assertEqual(calls, [{"tool": "cmux-ci-sim-create", "args": ["cmux-next-ios-sim", "iPhone-17", "iOS-26-5", "/work/sims"]}])

    def test_the_worker_helper_without_a_set_is_the_default_set(self):
        calls = self.run_create("cmux-next-ios-sim-test-k", "iPhone-17", "iOS-26-5")
        self.assertEqual(calls, [{"tool": "cmux-ci-sim-create", "args": ["cmux-next-ios-sim-test-k", "iPhone-17", "iOS-26-5"]}])

    def test_without_the_helper_it_is_the_stock_simctl_create(self):
        self.assertEqual(self.run_create("n", "t", "r", "/work/sims", helper=False),
                         [{"tool": "xcrun", "args": ["simctl", "--set", "/work/sims", "create", "n", "t", "r"]}])
        self.assertEqual(self.run_create("n", "t", "r", helper=False),
                         [{"tool": "xcrun", "args": ["simctl", "create", "n", "t", "r"]}])

    def test_every_simulator_the_step_makes_goes_through_sim_create(self):
        script = SCRIPT.read_text()
        outside = script.replace(sim_create_block(), "")
        creates = [line for line in outside.splitlines() if re.search(r"\bsimctl\b.*\bcreate\b", line) and not line.lstrip().startswith("#")]
        self.assertEqual(creates, [])
        self.assertEqual(len(re.findall(r'\$\(sim_create ', outside)), 4)


if __name__ == "__main__":
    unittest.main()
