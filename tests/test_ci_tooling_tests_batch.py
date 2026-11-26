#!/usr/bin/env python3
"""cmux-next-tooling-tests-batch.yml runs every step of cmux-next-guards.yml's tooling-tests job, and a pull request
leaves the steps only a wide reach selects to it (tooling_steps.py route --pr-scope)."""
from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import tooling_steps  # noqa: E402

GUARDS = ROOT / ".github/workflows/cmux-next-guards.yml"
BATCH = ROOT / ".github/workflows/cmux-next-tooling-tests-batch.yml"


def steps_of(path: Path) -> list[dict]:
    return yaml.safe_load(path.read_text())["jobs"]["tooling-tests"]["steps"]


class ToolingTestsBatch(unittest.TestCase):
    def test_the_batch_job_has_the_guards_jobs_steps(self) -> None:
        want = copy.deepcopy(steps_of(GUARDS))
        got = steps_of(BATCH)
        self.assertEqual(len(want), len(got))
        for w, g in zip(want, got):
            if w.get("uses", "").startswith("actions/checkout") and w.get("with", {}).get("fetch-depth") == 2:
                w["with"]["ref"] = "${{ inputs.sha || '' }}"
            # The batch's registry check only warns, on any event: the push-only WARN_ONLY is `--warn-only` here,
            # in the registry step and in the side-by-side runner that runs it.
            if w.get("id") in ("tt-test-registry", "setup-tooling-run") and "WARN_ONLY" in w.get("env", {}):
                w["env"]["WARN_ONLY"] = "--warn-only"
            self.assertEqual(w, g, w.get("name"))

    def test_the_pull_request_scope_switch_is_wired(self) -> None:
        text = GUARDS.read_text()
        self.assertIn("vars.CI_TOOLING_TESTS_PR_SCOPE", text)
        self.assertIn("--pr-scope", text)

    def test_pr_scope_defers_only_wide_reasons(self) -> None:
        verdicts = [
            tooling_steps.StepVerdict("a", "a", True, "tests/x.py lists every tracked file"),
            tooling_steps.StepVerdict("b", "b", True, "s.sh reads directory webviews, which holds webviews/a.ts"),
            tooling_steps.StepVerdict("c", "c", True, "t.py names a.md"),
            tooling_steps.StepVerdict("d", "d", True, "t.py lists a/**, which matches a/b"),
            tooling_steps.StepVerdict("e", "e", True, "reads tests/test_e.py"),
            tooling_steps.StepVerdict("f", "f", True, "its run text names no test the walker resolves"),
            tooling_steps.StepVerdict("g", "g", True, "x matches its declared input y (scripts/ci/tooling-step-inputs.json)"),
            tooling_steps.StepVerdict("", "h", True, "no id: it carries no selection and always runs"),
            tooling_steps.StepVerdict("i", "i", False, "none of its 3 inputs changed"),
        ]
        out = tooling_steps.narrow(tooling_steps.Decision(False, "1 changed file(s)", verdicts))
        self.assertEqual([s.run for s in out.steps], [False, False, False, False, True, True, True, True, False])
        self.assertEqual(out.selected, ["e", "f", "g", ""])
        wide = tooling_steps.Decision(True, "event push", verdicts)
        self.assertEqual(tooling_steps.narrow(wide).all, True)


if __name__ == "__main__":
    unittest.main()
