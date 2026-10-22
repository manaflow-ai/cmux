#!/usr/bin/env python3
"""The CEF shim C++ tests run on Linux, not a Mac.

Every scripts/cmux-next/test-*-cpp.sh compiles one header-only rule with no
CEF and no Apple SDK, so cmux-next-shim-cpp.yml runs them on Blacksmith Linux.
These contracts keep it that way: each script takes its compiler from
scripts/cmux-next/lib/cxx.sh (CXX, else xcrun clang++ on a Mac, else clang++)
instead of calling xcrun itself, the workflow runs every script, and its job
keeps the name required checks and the stall tools match on.
"""

import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-shim-cpp.yml"
SCRIPTS = sorted((ROOT / "scripts" / "cmux-next").glob("test-*-cpp.sh"))
JOB_NAME = "CEF shim download state (C++)"


def job() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["shim-downloads-cpp"]


class ShimCppLinuxTests(unittest.TestCase):
    def test_scripts_exist(self) -> None:
        self.assertGreaterEqual(len(SCRIPTS), 10)

    def test_scripts_take_the_shared_compiler(self) -> None:
        for script in SCRIPTS:
            text = script.read_text(encoding="utf-8")
            with self.subTest(script=script.name):
                self.assertIn('source "$root/scripts/cmux-next/lib/cxx.sh"', text)
                self.assertIsNone(re.search(r"^\s*[^#\n]*\bxcrun\b", text, re.M))

    def test_workflow_runs_every_script(self) -> None:
        runs = "\n".join(step.get("run", "") for step in job()["steps"])
        for script in SCRIPTS:
            with self.subTest(script=script.name):
                self.assertIn(f"./scripts/cmux-next/{script.name}", runs)

    def test_job_runs_on_linux_and_keeps_its_name(self) -> None:
        shim = job()
        self.assertEqual(shim["name"], JOB_NAME)
        runs_on = shim["runs-on"]
        self.assertIn("ubuntu", runs_on)
        self.assertNotIn("macos", runs_on)
        self.assertNotIn("LANE_RUNNER", runs_on)
        steps = "\n".join(step.get("run", "") for step in shim["steps"])
        self.assertNotIn("select-ci-xcode", steps)


if __name__ == "__main__":
    unittest.main()
