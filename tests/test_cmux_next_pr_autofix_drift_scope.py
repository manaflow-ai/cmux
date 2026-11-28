#!/usr/bin/env python3
"""The PR autofix's `generated drift` job skips a change with no generated output among its paths.

generated_outputs.py drift flags only a changed path that is a generated output, so a change without one cannot
fail it; its own runner and checkout on every head cost about 2,100 runner-min/day (2026-11-24) to pass on 97 % of
heads. action-areas decides it from the same list and the base's script; any doubt leaves the output empty and the
job runs. Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period."
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-pr-autofix.yml"


def jobs() -> dict:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]


def generated_step() -> dict:
    return next(s for s in jobs()["action-areas"]["steps"] if s.get("id") == "generated")


class DriftScopeTests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.temp)

    def run_step(self, changed: list[str], with_script: bool = True) -> tuple[int, str]:
        lib = self.temp / "autofix/scripts/cmux-next"
        lib.mkdir(parents=True, exist_ok=True)
        if with_script:
            shutil.copytree(ROOT / "scripts/cmux-next", lib, dirs_exist_ok=True)
        (self.temp / "changed.txt").write_text("".join(f"{p}\n" for p in changed))
        out = self.temp / "out"
        out.write_text("")
        env = {**os.environ, "RUNNER_TEMP": str(self.temp), "GITHUB_OUTPUT": str(out)}
        proc = subprocess.run(["bash", "-c", generated_step()["run"]], env=env, capture_output=True, text=True)
        return proc.returncode, out.read_text()

    def test_no_generated_output_skips_the_drift_job(self):
        self.assertEqual(self.run_step(["cmux-tui/src/lib.rs", "README.md"]), (0, "generated=false\n"))

    def test_a_changed_generated_output_runs_it(self):
        self.assertEqual(self.run_step(["plans/cmux-next/actions.md"]), (0, "generated=true\n"))

    def test_a_base_without_the_script_leaves_it_running(self):
        rc, out = self.run_step(["x.rs"], with_script=False)
        self.assertEqual((rc, out), (0, ""))

    def test_the_step_never_fails_action_areas_and_needs_the_list(self):
        step = generated_step()
        self.assertTrue(step["continue-on-error"])
        self.assertEqual(step["if"], "steps.changed.outputs.listed == 'true'")
        self.assertEqual(jobs()["action-areas"]["outputs"]["generated"], "${{ steps.generated.outputs.generated }}")

    def test_the_drift_job_skips_only_on_an_explicit_false(self):
        self.assertIn("needs.action-areas.outputs.generated != 'false'", jobs()["generated-drift"]["if"])


if __name__ == "__main__":
    unittest.main()
