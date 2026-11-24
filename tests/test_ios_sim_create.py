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

    def run_flaky(self, failures, *args):
        """sim_create with a stock simctl whose first FAILURES creates fail as CoreSimulator's stuck
        creation does, leaving a device of that name behind (and one of another name, never touched)."""
        tmp = tempfile.TemporaryDirectory(prefix="cmux-sim-create-")
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        binaries = root / "bin"
        binaries.mkdir()
        (binaries / "xcrun").write_text(r'''#!/usr/bin/env python3
import json, os, sys
calls = os.environ["CALLS"]
with open(calls, "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
args = [a for a in sys.argv[1:] if a not in ("simctl",)]
if "--set" in args:
    i = args.index("--set"); del args[i:i + 2]
if args[0] == "create":
    n = sum(1 for line in open(calls) if '"create"' in line)
    if n <= int(os.environ["FAILURES"]):
        print("Device was allocated but was stuck in creation state.", file=sys.stderr)
        sys.exit(1)
    print("AAAAAAAA-0000-0000-0000-000000000001")
elif args[:3] == ["list", "-j", "devices"]:
    print(json.dumps({"devices": {"rt": [{"name": os.environ["NAME"], "udid": "STUCK-1"},
                                          {"name": "another-step", "udid": "OTHER-1"}]}}))
''')
        (binaries / "xcrun").chmod(0o755)
        calls = root / "calls.jsonl"
        harness = root / "create.sh"
        harness.write_text("set -euo pipefail\n" + sim_create_block() + '\nudid="$(sim_create "$@")"\necho "$udid"\n')
        env = {**os.environ, "PATH": f"{binaries}{os.pathsep}{os.environ['PATH']}", "CALLS": str(calls),
               "FAILURES": str(failures), "NAME": args[0]}
        env.pop("CMUX_CI_SIM_CREATE", None)
        run = subprocess.run(["bash", str(harness), *args], env=env, text=True, capture_output=True, timeout=20)
        return run, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_a_stuck_creation_is_deleted_by_its_name_and_tried_again(self):
        run, calls = self.run_flaky(1, "cmux-next-ios-sim", "iPhone-17", "iOS-26-5", "/work/sims")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stdout.strip(), "AAAAAAAA-0000-0000-0000-000000000001")
        creates = [c for c in calls if "create" in c]
        self.assertEqual(len(creates), 2)
        deletes = [c for c in calls if "delete" in c]
        self.assertEqual(deletes, [["simctl", "--set", "/work/sims", "delete", "STUCK-1"]])

    def test_a_stuck_creation_in_the_default_set_deletes_only_that_name(self):
        run, calls = self.run_flaky(2, "cmux-next-ios-sim-test-k", "iPhone-17", "iOS-26-5")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len([c for c in calls if "create" in c]), 3)
        self.assertEqual([c for c in calls if "delete" in c], [["simctl", "delete", "STUCK-1"]] * 2)

    def test_three_failed_creations_fail_the_step(self):
        run, calls = self.run_flaky(3, "cmux-next-ios-sim", "iPhone-17", "iOS-26-5", "/work/sims")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(len([c for c in calls if "create" in c]), 3)
        self.assertIn("could not create cmux-next-ios-sim in 3 attempts", run.stderr)

    def test_the_steps_iphone_is_made_before_the_build(self):
        script = SCRIPT.read_text()
        self.assertIn("sim_name=cmux-next-ios-sim\n", script)
        made = script.index('udid="$(sim_create "$sim_name" ')
        self.assertLess(made, script.index("# --- Build ---"))
        self.assertLess(script.index("# --- end sim_create"), made)

    def test_every_simulator_the_step_makes_goes_through_sim_create(self):
        script = SCRIPT.read_text()
        outside = script.replace(sim_create_block(), "")
        creates = [line for line in outside.splitlines() if re.search(r"\bsimctl\b.*\bcreate\b", line) and not line.lstrip().startswith("#")]
        self.assertEqual(creates, [])
        self.assertEqual(len(re.findall(r'\$\(sim_create ', outside)), 4)


if __name__ == "__main__":
    unittest.main()
