#!/usr/bin/env python3
"""A job portable placement may put on a mini brings its own PyYAML before it runs Python tests.

scripts/ci/portable_job_placement.py places each job a workflow's placement step names in JOBS on fleet Linux, then
on a free mini, then Blacksmith; LINUX_ONLY jobs never take a mini. A mini's Homebrew python3 has no PyYAML. On
2026-11-11 cmux-next.yml's `checks` job went red on cmux13s-mac-mini-glaeda-5 (job 130627140300) and
cmuxs-mac-mini-6-glaeda-3 (job 130624833630) with `ModuleNotFoundError: No module named 'yaml'` and passed on
Blacksmith Linux at the same tree, so merge_hold read it as a pull request's own red. cmux-next-guards.yml's tooling
tests met the same on cmux14 on 2026-11-03 and fixed only themselves.

So: every mini-eligible job with a step that runs repository Python tests (tests/*.py or a unittest run) has an
earlier step that installs PyYAML into a venv and puts it first on PATH (GITHUB_PATH).
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
# A command that runs repository Python tests: python3 [-flags] tests/x.py, a unittest or pytest run, or the checks
# runner. A path named in a comment or docstring is no run (ci-guards.yml's PYTHON_RULE copy names one).
RUNS_TESTS = re.compile(r"^\s*(?:[\w.=/$\"{}-]+\s+)*?python3?(?:\s+-\w+)*\s+"
                        r"(?:tests/[\w./-]+\.py|-m\s+(?:unittest|pytest))\b|run-checks-concurrently\.sh", re.M)


def brings_pyyaml(run: str) -> bool:
    return "venv" in run and "PyYAML" in run and "GITHUB_PATH" in run


def mini_eligible_jobs(jobs: dict) -> set[str]:
    """The jobs a placement step in JOBS may put on a mini: those in its JOBS and not in its LINUX_ONLY."""
    found: set[str] = set()
    for job in jobs.values():
        for step in (job.get("steps") or []) if isinstance(job, dict) else []:
            env = step.get("env") or {}
            if "portable_job_placement.py" in str(step.get("run") or "") and env.get("JOBS"):
                found |= set(str(env["JOBS"]).split()) - set(str(env.get("LINUX_ONLY") or "").split())
    return found


def missing(jobs: dict) -> list[tuple[str, str]]:
    """(job, step) for each mini-eligible job's first step that runs Python tests before any step brings PyYAML."""
    gaps = []
    for job_id in sorted(mini_eligible_jobs(jobs)):
        for step in jobs.get(job_id, {}).get("steps") or []:
            run = str(step.get("run") or "")
            if brings_pyyaml(run):
                break
            if RUNS_TESTS.search(run):
                gaps.append((job_id, str(step.get("name"))))
                break
    return gaps


class PortableJobsBringTheirPython(unittest.TestCase):
    def test_every_mini_eligible_job_brings_pyyaml_before_its_tests(self):
        for path in sorted(WORKFLOWS.glob("*.yml")):
            jobs = yaml.safe_load(path.read_text(encoding="utf-8")).get("jobs") or {}
            with self.subTest(workflow=path.name):
                self.assertEqual(missing(jobs), [], "a job portable placement may put on a mini runs Python tests "
                                                    "before it brings PyYAML: add a venv step like cmux-next.yml "
                                                    "checks' 'Prepare check Python (PyYAML) and timeout', or list "
                                                    "the job in the placement step's LINUX_ONLY")

    def test_the_checks_job_is_covered(self):
        jobs = yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text(encoding="utf-8"))["jobs"]
        self.assertIn("checks", mini_eligible_jobs(jobs))

    def test_the_rule_finds_a_job_without_it(self):
        place = {"steps": [{"run": "python3 scripts/ci/portable_job_placement.py",
                            "env": {"JOBS": "a b c", "LINUX_ONLY": "c"}}]}
        jobs = {"place": place,
                "a": {"steps": [{"run": "python3 tests/test_x.py"}]},
                "b": {"steps": [{"run": 'python3 -m venv v; v/bin/pip install PyYAML; echo v >> "$GITHUB_PATH"'},
                                {"run": "python3 tests/test_x.py"}]},
                "c": {"steps": [{"run": "python3 tests/test_x.py"}]}}
        self.assertEqual(missing(jobs), [("a", "None")])


if __name__ == "__main__":
    unittest.main()
