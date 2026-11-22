"""Every job marked `# ephemeral-required` (a write token or App key) leads with a one-job GCP JIT label.

Leo, 2026-11-21: "i just am like fundamentally opposed to paying for ci when i exist". These small bot jobs used to
name a Blacksmith size first. A Blacksmith size is also registered by the persistent runner pool, so a job could land
there and fail its own ephemeral guard. The JIT labels (cmuxterm-hq runner_pool.py JIT_ONLY_LABELS) are served only by
one-job VMs the fleet reconciler boots per queued job and deletes after it, with no persistent runner on them.

Each job names its label right after the fork branch, behind that label's own switch variable (=1 puts the job back on
the Blacksmith selector after it, as an overflow route nothing depends on). A job may not lead with a label under
another label's switch, nor with a persistent-pool label.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
FORK_BRANCH = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
# switch variable -> the one label it may turn off
SWITCHES = {
    "CI_REPAIR_SKIP_FLEET": "cmux-gcp-repair-jit-x64",
    "CI_PR_CONTROL_SKIP_FLEET": "cmux-gcp-pr-control-jit-x64",
    "CI_GATE_SKIP_FLEET": "cmux-gcp-gate-jit-x64",
}
LEAD = re.compile(
    r"(?:\([^()]*\) && )?vars\.(CI_[A-Z_]+_SKIP_FLEET) != '1' && '(cmux-gcp-[a-z-]+-jit-x64)' \|\| "
)
# (workflow, line number is not pinned) -> why the job does not lead with a JIT label yet.
EXCEPTIONS = {
    "cla.yml": "the CLA Assistant moves to the gate label with its policy PR (exact-head human approval)",
    "resolve-runners.yml": "the resolver reads no runner variable and must not depend on a fleet it resolves",
}


def marked_jobs() -> list[tuple[str, int, str]]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("runs-on:") and "# ephemeral-required" in stripped:
                found.append((path.name, number, stripped.removeprefix("runs-on:").split(" # ", 1)[0].strip()))
    return found


class WriteTokenJitLabelTests(unittest.TestCase):
    def test_marker_scan_is_not_vacuous(self) -> None:
        self.assertGreater(len(marked_jobs()), 30)

    def test_every_ephemeral_required_job_leads_with_a_jit_label(self) -> None:
        failures = []
        for name, number, runs_on in marked_jobs():
            if name in EXCEPTIONS:
                continue
            # The fork branch, then optionally a fork-pull-request hosted branch, then the JIT operand.
            rest = runs_on[len(FORK_BRANCH):] if runs_on.startswith(FORK_BRANCH) else None
            if rest is not None and rest.startswith("github.event_name == 'pull_request' && "):
                rest = rest.split(" || ", 1)[1]
            matched = LEAD.match(rest) if rest is not None else None
            if matched is None:
                failures.append(f"{name}:{number} does not lead with a JIT label: {runs_on}")
            elif SWITCHES.get(matched.group(1)) != matched.group(2):
                failures.append(f"{name}:{number} leads with {matched.group(2)} under {matched.group(1)}")
        self.assertEqual(failures, [])

    def test_the_exceptions_are_still_needed(self) -> None:
        names = {name for name, _, _ in marked_jobs()}
        for name in EXCEPTIONS:
            self.assertIn(name, names, f"stale exception {name}")

    def test_the_switch_variables_are_passed_to_the_runs_on_value_check(self) -> None:
        text = (WORKFLOWS / "ci-repo-variables.yml").read_text(encoding="utf-8")
        for variable in SWITCHES:
            self.assertIn(f"{variable}=${{{{ vars.{variable} }}}}", text)


if __name__ == "__main__":
    unittest.main()
