#!/usr/bin/env python3
"""The nightly's and the DEV publisher's Mac jobs never wait on one Blacksmith label.

On 2026-10-27 between 12:03 and 12:46Z blacksmith-12vcpu-macos-26 started nothing and
blacksmith-6vcpu-macos-26 started about one job a minute with the oldest waiting 52 min, while
the sign, verify and publish jobs here named 'blacksmith-6vcpu-macos-26' as their only label.

Every macOS runs-on in these workflows (bar EXEMPT) must:
- read a picker output that chooses a Blacksmith macOS 26 label with a moving queue, before the
  literal it falls back to, and
- on a re-run (attempt 2 on) read the picker's `alternate`, the other label, so a re-run never
  queues again on the label that stalled after the pick,
- and end in a literal Blacksmith label, so an empty pick still runs.
The picker is scripts/ci/classic_nightly_build_runner.py (Blacksmith macOS 26 only: both its
candidates are blacksmith-* labels).
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import classic_nightly_build_runner as picker  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
CHECKED = ("nightly.yml", "cmux-next-dev-daily.yml")
# Jobs that keep one label, and why.
EXEMPT = {
    ("nightly.yml", "refresh-compilation-cache"):
        "a cache warmer on a schedule or a seed_only dispatch; nothing ships from it and nothing waits on it",
    ("nightly.yml", "build-nightly-ghostty-cli-helper"):
        "the SDK 15 helper needs the macOS 15 image (no macOS 26 Blacksmith label carries SDK 15)",
    ("nightly.yml", "build-nightly-app"):
        "pick-nightly-app-runner (cmux#26208) routes it; tests/test_classic_nightly_build_runner.py covers it",
}
MOVING = re.compile(r"needs\.([a-z0-9-]+)\.outputs\.(cloud|runner)\b")
ALTERNATE = re.compile(r"github\.run_attempt > 1 && needs\.([a-z0-9-]+)\.outputs\.attempt != github\.run_attempt"
                       r" && needs\.\1\.outputs\.alternate \|\|")
LAST_LITERAL = re.compile(r"\|\| '(blacksmith-[0-9]+vcpu-macos-26)'\)?\s*\}\}$")


def mac_jobs() -> list[tuple[str, str, dict, dict]]:
    found = []
    for workflow in CHECKED:
        jobs = (yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8")) or {}).get("jobs") or {}
        for name, job in jobs.items():
            if isinstance(job, dict) and "macos" in str(job.get("runs-on", "")):
                found.append((workflow, name, job, jobs))
    return found


def needs(job: dict) -> list[str]:
    value = job.get("needs") or []
    return [value] if isinstance(value, str) else list(value)


def problems(workflow: str, name: str, job: dict, jobs: dict) -> list[str]:
    runs_on = str(job.get("runs-on", ""))
    out = []
    moving = MOVING.findall(runs_on)
    alternate = ALTERNATE.findall(runs_on)
    literal = LAST_LITERAL.search(runs_on)
    if not moving:
        out.append("reads no moving Blacksmith pick")
    if not alternate:
        out.append("has no `github.run_attempt > 1 && needs.<picker>.outputs.attempt != github.run_attempt && "
                   "needs.<picker>.outputs.alternate ||` for a re-run")
    if not literal:
        out.append("does not end in a literal blacksmith-<n>vcpu-macos-26 label")
    for source in {job_name for job_name, _ in moving} | set(alternate):
        if source not in needs(job):
            out.append(f"reads {source} without needing it")
            continue
        source_job = jobs.get(source) or {}
        steps = [step for step in source_job.get("steps") or [] if isinstance(step, dict)]
        if not any("classic_nightly_build_runner.py" in str(step.get("run", "")) for step in steps):
            out.append(f"{source} does not run classic_nightly_build_runner.py")
        # A pick that fails leaves its outputs empty and the literal takes the job, so the pick never
        # skips it: the consumer's `if` does not rely on the implicit success().
        condition = str(job.get("if", "")).replace("${{", "").strip().strip('"')
        if not condition.startswith(("!cancelled()", "always()")):
            out.append(f"reads {source} but its `if` is the implicit success(), so a failed pick would skip it")
    if literal and moving and runs_on.index(literal.group(0)) < runs_on.index(f"needs.{moving[0][0]}"):
        out.append("the literal comes before the pick")
    return [f"{workflow} {name}: {problem}" for problem in out]


class PublisherMacJobsMove(unittest.TestCase):
    def test_the_picker_names_only_blacksmith_macos_26(self) -> None:
        self.assertEqual(set(picker.CANDIDATES), {picker.SMALL, picker.LARGE})
        self.assertTrue(all(re.fullmatch(r"blacksmith-[0-9]+vcpu-macos-26", label) for label in picker.CANDIDATES))

    def test_every_mac_job_reads_a_moving_pick_and_a_rerun_alternate(self) -> None:
        jobs = mac_jobs()
        checked = {(workflow, name) for workflow, name, _, _ in jobs}
        # The sign, verify, notarize and DEV publish jobs Leo's order names.
        for required in (("nightly.yml", "build-sign-notarize-nightly"), ("nightly.yml", "verify-signed-nightly"),
                         ("cmux-next-dev-daily.yml", "verify"), ("cmux-next-dev-daily.yml", "tip-dmg-build"),
                         ("cmux-next-dev-daily.yml", "tip-deltas")):
            self.assertIn(required, checked)
        bad = [problem for workflow, name, job, all_jobs in jobs if (workflow, name) not in EXEMPT
               for problem in problems(workflow, name, job, all_jobs)]
        self.assertEqual(bad, [], "\n".join(bad))

    def test_the_exemptions_name_real_jobs(self) -> None:
        checked = {(workflow, name) for workflow, name, _, _ in mac_jobs()}
        self.assertEqual(sorted(set(EXEMPT) - checked), [])

    def test_the_rule_refuses_a_lone_label(self) -> None:
        jobs = {"pick": {"steps": [{"run": "python3 scripts/ci/classic_nightly_build_runner.py"}]}}
        lone = {"runs-on": "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || 'blacksmith-6vcpu-macos-26' }}"}
        self.assertTrue(problems("x.yml", "j", lone, jobs))
        no_rerun = {"needs": ["pick"], "runs-on": "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
                    "needs.pick.outputs.cloud || 'blacksmith-6vcpu-macos-26' }}"}
        self.assertTrue(problems("x.yml", "j", no_rerun, jobs))
        good = {"needs": ["pick"], "if": "!cancelled()", "runs-on": "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
                "github.run_attempt > 1 && needs.pick.outputs.attempt != github.run_attempt && needs.pick.outputs.alternate || "
                "needs.pick.outputs.cloud || "
                "'blacksmith-6vcpu-macos-26' }}"}
        self.assertEqual(problems("x.yml", "j", good, jobs), [])
        self.assertTrue(problems("x.yml", "j", {**good, "needs": []}, jobs))
        self.assertTrue(problems("x.yml", "j", {**good, "if": "needs.a.result == 'success'"}, jobs))
        self.assertTrue(problems("x.yml", "j", good, {"pick": {"steps": [{"run": "echo blacksmith-6vcpu-macos-26"}]}}))


if __name__ == "__main__":
    unittest.main()
