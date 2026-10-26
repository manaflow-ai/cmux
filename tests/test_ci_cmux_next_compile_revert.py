#!/usr/bin/env python3
"""A feat-cmux-next push whose Mac Release compile fails opens the revert of the one merge since its last pass."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import cmux_next_compile_revert as revert  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next.yml"


def job(conclusion: str, step: str = "Release compile", step_conclusion: str | None = None) -> dict:
    return {"name": revert.GATE, "conclusion": conclusion,
            "steps": [{"name": "Set up job", "conclusion": "success"},
                      {"name": step, "conclusion": step_conclusion or conclusion}]}


class Verdict(unittest.TestCase):
    def test_only_a_compile_step_failure_counts(self):
        self.assertTrue(revert.compiler_failed([job("failure")]))
        self.assertTrue(revert.compiler_failed([job("skipped"), job("failure", "Record the Release compile admission")]))
        # A lost runner, a timeout or a failed setup step is not the compiler's verdict.
        self.assertFalse(revert.compiler_failed([job("failure", step_conclusion="success")]))
        self.assertFalse(revert.compiler_failed([job("timed_out")]))
        self.assertFalse(revert.compiler_failed([job("cancelled")]))
        self.assertFalse(revert.compiler_failed([]))

    def test_a_pass_of_either_gate_job_is_a_pass(self):
        self.assertEqual(revert.gate_conclusion([job("skipped"), job("success")]), "success")
        self.assertEqual(revert.gate_conclusion([job("skipped"), job("failure")]), "failure")
        self.assertEqual(revert.gate_conclusion([job("skipped")]), "")

    def test_only_a_single_merge_is_a_culprit(self):
        self.assertEqual(revert.culprit([25001]), 25001)
        self.assertIsNone(revert.culprit([]))
        self.assertIsNone(revert.culprit([25001, 25002]))


class Main(unittest.TestCase):
    def run_main(self, responses: dict, tmp: Path) -> dict[str, str]:
        def fake(path: str):
            for prefix, value in responses.items():
                if path.startswith(prefix):
                    return value
            raise AssertionError(path)

        out = tmp / "out"
        with mock.patch.object(revert, "gh_api", side_effect=fake), \
                mock.patch.object(revert, "pull_requests", return_value=responses["__prs"]):
            revert.main(["--repo", "o/r", "--run-id", "300", "--sha", "c" * 40, "--github-output", str(out)])
        values: dict[str, str] = {}
        for line in out.read_text().splitlines():
            key, _, value = line.partition("=")
            values[key] = value
        return values

    def responses(self, prs: list[int]) -> dict:
        return {
            "repos/o/r/actions/runs/300/jobs": {"jobs": [job("failure")]},
            "repos/o/r/actions/workflows/cmux-next.yml/runs": {"workflow_runs": [
                {"id": 299, "head_sha": "b" * 40}, {"id": 298, "head_sha": "a" * 40}]},
            "repos/o/r/actions/runs/299/jobs": {"jobs": [job("skipped")]},
            "repos/o/r/actions/runs/298/jobs": {"jobs": [job("success")]},
            "repos/o/r/pulls/": {"base": {"ref": "feat-cmux-next"}, "merged_at": "x", "merge_commit_sha": "d" * 40},
            "__prs": prs,
        }

    def test_one_merge_since_the_last_pass_is_named(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            values = self.run_main(self.responses([25001]), Path(tmp))
        self.assertEqual(values["pr"], "25001")
        self.assertEqual(values["merge_sha"], "d" * 40)
        self.assertEqual(values["good"], "a" * 40)

    def test_several_merges_open_nothing(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            values = self.run_main(self.responses([25001, 25002]), Path(tmp))
        self.assertEqual(values["pr"], "")


class WorkflowJob(unittest.TestCase):
    def test_it_runs_after_a_failed_base_push_compile_only(self):
        job_ = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["release-compile-revert"]
        self.assertEqual(job_["needs"], ["release-compile", "release-compile-fast-admission"])
        for needle in ("needs.release-compile.result == 'failure'", "needs.release-compile-fast-admission.result == 'failure'",
                       "github.event_name == 'push'", "github.ref == 'refs/heads/feat-cmux-next'"):
            self.assertIn(needle, job_["if"])
        # No write permission on the workflow token: the App token pushes and opens the revert.
        self.assertEqual(job_["permissions"], {"actions": "read", "contents": "read"})
        self.assertFalse(job_["concurrency"]["cancel-in-progress"])
        run = "\n".join(step.get("run", "") for step in job_["steps"])
        self.assertIn("cmux_next_compile_revert.py", run)
        self.assertIn("git revert --no-edit", run)
        self.assertIn("base=feat-cmux-next", run)


if __name__ == "__main__":
    unittest.main()
