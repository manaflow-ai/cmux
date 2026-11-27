#!/usr/bin/env python3
"""The cmux NEXT DEV Release compile builds the browser-data import the way
published nightly-next builds do, and only that step sets it.

Apple held the import with status 7000 on 2026-10-09, so both compiled it out
(cx-f58x). Apple accepted it again in run 42176643049, and nightly-next ships
it in since run 42205166616 (nightly.yml NIGHTLY_NEXT_BROWSER_DATA_IMPORT=full).
The DEV app is the tip app (Leo, 2026-10-24), so it carries the import too;
`compiled-out` in both files is the switch back.

The step runs no proof: check-browser-data-import-absent.sh fails on the
bundled cmux CLI (Contents/Resources/bin/cmux), which every notarized
nightly-next build also ships, and a failed proof there stopped every DEV
publish (run 40133576073; reverted in #25050).
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workflow_jobs  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = workflow_jobs.document(ROOT / ".github/workflows/cmux-next.yml")
NIGHTLY = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())
SCRIPT = (ROOT / "scripts/cmux-next/check-cmux-scheme-compile.sh").read_text()
DEV_STEP = "Compile the cmux NEXT DEV Release app"


def steps():
    for name, job in WORKFLOW["jobs"].items():
        for step in job.get("steps") or []:
            yield name, step


class DevReleaseImportOut(unittest.TestCase):
    def dev_steps(self):
        # The DEV run's (cmux-scheme-compile) and the landing compile's, which records the same app.
        found = {name: step for name, step in steps() if step.get("name") == DEV_STEP}
        self.assertEqual(sorted(found), ["cmux-scheme-compile", "dev-landing-compile"])
        return list(found.values())

    def test_the_dev_app_carries_the_import_as_published_nightly_next_builds_do(self):
        nightly = NIGHTLY["env"]["NIGHTLY_NEXT_BROWSER_DATA_IMPORT"]
        self.assertEqual(nightly, "full")
        for step in self.dev_steps():
            self.assertEqual(step["env"].get("CMUX_NEXT_BROWSER_DATA_IMPORT"), nightly)
        # The REF capture steps key the DEV build on the compile's settings, one NAME=VALUE a line.
        captures = [step["env"]["HYBRID_REF_SETTINGS"] for _, step in steps()
                    if "HYBRID_REF_SETTINGS" in (step.get("env") or {})]
        self.assertEqual(len(captures), 2)
        for settings in captures:
            self.assertIn(f"CMUX_NEXT_BROWSER_DATA_IMPORT={nightly}\n", settings)

    def test_only_the_dev_release_step_sets_the_import(self):
        others = [step.get("name") for _, step in steps()
                  if step.get("name") != DEV_STEP
                  and "CMUX_NEXT_BROWSER_DATA_IMPORT" in (step.get("env") or {})]
        self.assertEqual(others, [], "another step compiles the import out")
        jobs = [name for name, job in WORKFLOW["jobs"].items()
                if "CMUX_NEXT_BROWSER_DATA_IMPORT" in workflow_jobs.resolve(job).env]
        self.assertEqual(jobs, [], "a job-wide setting would reach the Debug compile")
        self.assertNotIn("CMUX_NEXT_BROWSER_DATA_IMPORT", WORKFLOW.get("env") or {})

    def test_the_dev_step_runs_no_proof_that_could_hold_the_zip(self):
        for step in self.dev_steps():
            self.assertNotIn("check-browser-data-import-absent.sh", step["run"])
            self.assertNotIn("check-password-import-readers.sh", step["run"])

    def test_the_script_still_has_the_hook(self):
        self.assertIn('browser_data_import="${CMUX_NEXT_BROWSER_DATA_IMPORT:-built-in}"', SCRIPT)
        self.assertIn("-DCMUX_NO_PASSWORD_IMPORT -DCMUX_NO_BROWSER_DATA_IMPORT", SCRIPT)


if __name__ == "__main__":
    unittest.main()
