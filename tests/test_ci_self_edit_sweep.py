#!/usr/bin/env python3
"""A workflow sweep does not start a heavy journey whose own .yml is the only path that reached it.

Pins scripts/ci/self_edit_sweep.py's rule and how each gated journey calls .github/workflows/self-edit-sweep.yml:
the caller job starts only on a pull request with at least SWEEP_MIN_WORKFLOWS changed files and no full-ci label,
and every root heavy job runs unless the gate answers run=false (a failed or skipped gate runs it).

Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period."

Run: python3 tests/test_ci_self_edit_sweep.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import self_edit_sweep as sweep  # noqa: E402

WORKFLOWS = ROOT / ".github/workflows"
GATE = "./.github/workflows/self-edit-sweep.yml"
# Each gated journey and the root jobs that spend its minutes.
GATED = {
    "cmux-next-degenerate-lab.yml": ["plan"],
    "migrate-journey-pr.yml": ["migrate"],
    "cloud-fork-placement.yml": ["measure"],
    "tailnet-stable-node-move.yml": ["move"],
    "repro-capsule-journey.yml": ["replay"],
    "cloud-chief-start.yml": ["check"],
    "cloud-chief-turn-proof.yml": ["proof"],
    "runnable-link.yml": ["measure"],
    "rfd0135-gates.yml": ["gates"],
    "vm-hassle.yml": ["hassle"],
    "zero-to-going.yml": ["measure"],
    "executor-journey.yml": ["journey"],
}
PATHS = [".github/workflows/vm-hassle.yml", "scripts/cmux-next/**", "crates/cmux-vm/**"]


def sweep_files(n: int) -> list[str]:
    return [f".github/workflows/w{i}.yml" for i in range(n)]


class TheRule(unittest.TestCase):
    def test_a_sweep_that_reaches_it_only_through_workflow_files_skips(self) -> None:
        run, why = sweep.decide(sweep_files(40) + [".github/workflows/vm-hassle.yml", "README.md"], PATHS, set())
        self.assertFalse(run, why)

    def test_a_sweep_that_also_changes_another_input_runs(self) -> None:
        self.assertTrue(sweep.decide(sweep_files(40) + ["scripts/cmux-next/vm.py"], PATHS, set())[0])

    def test_full_ci_runs_everything(self) -> None:
        self.assertTrue(sweep.decide(sweep_files(40), PATHS, {"full-ci"})[0])

    def test_fewer_workflow_files_than_a_sweep_runs(self) -> None:
        files = sweep_files(sweep.SWEEP_MIN_WORKFLOWS - 1) + ["a.txt"] * 20
        self.assertTrue(sweep.decide(files, PATHS, set())[0])
        self.assertFalse(sweep.decide(sweep_files(sweep.SWEEP_MIN_WORKFLOWS), PATHS, set())[0])

    def test_unknown_files_or_paths_run(self) -> None:
        self.assertTrue(sweep.decide(None, PATHS, set())[0])
        self.assertTrue(sweep.decide(sweep_files(40), None, set())[0])

    def test_the_switch_at_zero_turns_it_off(self) -> None:
        self.assertTrue(sweep.decide(sweep_files(40), PATHS, set(), switch="0")[0])

    def test_no_merge_commit_answers_unknown(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["git", "init", "-q", tmp], check=True)
            self.assertIsNone(sweep.changed_files(tmp))

    def test_the_merge_commit_diff_against_the_base_tip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            git = ["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
            subprocess.run(["git", "init", "-q", "-b", "base", tmp], check=True)
            (Path(tmp) / "a").write_text("a")
            subprocess.run(git + ["add", "a"], check=True)
            subprocess.run(git + ["commit", "-qm", "a"], check=True)
            subprocess.run(git + ["checkout", "-qb", "head"], check=True)
            (Path(tmp) / "b").write_text("b")
            subprocess.run(git + ["add", "b"], check=True)
            subprocess.run(git + ["commit", "-qm", "b"], check=True)
            subprocess.run(git + ["checkout", "-q", "base"], check=True)
            (Path(tmp) / "c").write_text("c")
            subprocess.run(git + ["add", "c"], check=True)
            subprocess.run(git + ["commit", "-qm", "c"], check=True)
            subprocess.run(git + ["merge", "-q", "--no-ff", "-m", "m", "head"], check=True)
            self.assertEqual(sweep.changed_files(tmp), ["b"])


class TheGatedJourneys(unittest.TestCase):
    def test_the_indentation_reader_matches_yaml_for_every_gated_journey(self) -> None:
        for name in GATED:
            text = (WORKFLOWS / name).read_text()
            with self.subTest(name):
                self.assertEqual(sweep._scan_paths(text), sweep.pull_request_paths(WORKFLOWS / name))
                self.assertIn(f".github/workflows/{name}", sweep._scan_paths(text) or [])

    def test_each_calls_the_gate_with_its_own_file_and_the_sweep_threshold(self) -> None:
        for name in GATED:
            jobs = yaml.safe_load((WORKFLOWS / name).read_text())["jobs"]
            gate = jobs.get("self-edit") or {}
            with self.subTest(name):
                self.assertEqual(gate.get("uses"), GATE)
                self.assertEqual(gate.get("with"), {"workflow": f".github/workflows/{name}"})
                cond = gate.get("if", "")
                self.assertIn("github.event_name == 'pull_request'", cond)
                self.assertIn(f"github.event.pull_request.changed_files >= {sweep.SWEEP_MIN_WORKFLOWS}", cond)
                self.assertIn("!contains(github.event.pull_request.labels.*.name, 'full-ci')", cond)

    def test_every_root_heavy_job_runs_unless_the_gate_answers_false(self) -> None:
        for name, roots in GATED.items():
            jobs = yaml.safe_load((WORKFLOWS / name).read_text())["jobs"]
            for root in roots:
                job = jobs[root]
                with self.subTest(f"{name}:{root}"):
                    needs = job.get("needs")
                    self.assertIn("self-edit", [needs] if isinstance(needs, str) else needs)
                    cond = job.get("if", "")
                    self.assertTrue(cond.startswith("${{ !cancelled() && needs.self-edit.outputs.run != 'false' && ("),
                                    cond)

    def test_the_gate_workflow_is_call_only_and_reads_the_switch(self) -> None:
        doc = yaml.safe_load((WORKFLOWS / "self-edit-sweep.yml").read_text())
        on = doc.get("on", doc.get(True))
        self.assertEqual(list(on), ["workflow_call"])
        step = doc["jobs"]["decide"]["steps"][-1]
        self.assertIn("self_edit_sweep.py decide", step["run"])
        self.assertIn("CI_SELF_EDIT_SWEEP_SKIP", step["env"])


if __name__ == "__main__":
    unittest.main()
