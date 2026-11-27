<<<<<<< HEAD
"""feat-cmux-next's bot and PR-control jobs lead with our own GCP Linux runners; Blacksmith is overflow behind a switch.

Leo, 2026-11-19, on Blacksmith: "stop ... relying on it". The rulebook: "Any build or test: Linux first (`cmux-ci`;
GCP and Freestyle, both first-class), then owned Macs; Blacksmith is an overflow switch nothing depends on."

On 2026-11-22 at 08:47Z blacksmith-4vcpu-ubuntu-2404 held 121 queued jobs (oldest 103 min) while the persistent GCP
pool had about 300 idle runners: most of that queue was this branch's `risk evidence` and `merge freeze`
(pull_request_target, so the base branch's copy runs), whose runs-on named only a Blacksmith size. main's copies already
lead with the one-job GCP JIT label (tests/test_ci_write_token_jit_label.py on main); this is the same rule here.

Every job marked `# ephemeral-required` (a write token or App key) leads, right after the fork branches, with a
one-job GCP JIT label (cmuxterm-hq runner_pool.py JIT_ONLY_LABELS: no persistent runner carries them) behind that
label's own switch variable; `=1` puts the job back on the Blacksmith selector after it, which is the overflow.
=======
"""Every job marked `# ephemeral-required` (a write token or App key) leads with a one-job GCP JIT label.

Leo, 2026-11-21: "i just am like fundamentally opposed to paying for ci when i exist". These small bot jobs used to
name a Blacksmith size first. A Blacksmith size is also registered by the persistent runner pool, so a job could land
there and fail its own ephemeral guard. The JIT labels (cmuxterm-hq runner_pool.py JIT_ONLY_LABELS) are served only by
one-job VMs the fleet reconciler boots per queued job and deletes after it, with no persistent runner on them.

Each job names its label right after the fork branch, behind that label's own switch variable (=1 puts the job back on
the Blacksmith selector after it, as an overflow route nothing depends on). A job may not lead with a label under
another label's switch, nor with a persistent-pool label.

Where the switch held one value, the job names the label it resolved to as a literal (goal linux-pickers-gone,
cmux main: no Linux `runs-on` reads a variable): a one-job JIT label, or the Blacksmith size the switch sent it to.
A literal is never a persistent-pool label.
>>>>>>> origin/main
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
FORK_BRANCH = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
<<<<<<< HEAD
FORK_PR = re.compile(r"(?:github\.event_name == 'pull_request' && )?github\.event\.pull_request\.head\.repo\.full_name "
                     r"!= github\.repository && 'blacksmith-[0-9]+vcpu-ubuntu-2404' \|\| ")
# switch variable -> the one JIT label it may turn off
=======
# switch variable -> the one label it may turn off
>>>>>>> origin/main
SWITCHES = {
    "CI_REPAIR_SKIP_FLEET": "cmux-gcp-repair-jit-x64",
    "CI_PR_CONTROL_SKIP_FLEET": "cmux-gcp-pr-control-jit-x64",
    "CI_GATE_SKIP_FLEET": "cmux-gcp-gate-jit-x64",
}
<<<<<<< HEAD
LEAD = re.compile(r"(?:\([^()]*\) && )?vars\.(CI_[A-Z_]+_SKIP_FLEET) != '1' && '(cmux-gcp-[a-z-]+-jit-x64)' \|\| ")
# workflow -> (marked lines that do not lead with a JIT label yet, why). A count, so a new unmoved job still fails.
EXCEPTIONS = {
    "backend-migrations.yml": (4, "the required migration checks move to the gate label with their own policy PR, as on main"),
    "pr-checks.yml": (1, "the advisory comment job left the PR control label when it backed up (tests/test_ci_runner_set.py)"),
    "cmux-next.yml": (2, "the push/PR control arms (tests/test_cmux_next_pr_control_on_jit.py)"),
}


def after_fork_branches(runs_on: str) -> str | None:
    if not runs_on.startswith(FORK_BRANCH):
        return None
    rest = runs_on[len(FORK_BRANCH):]
    fork = FORK_PR.match(rest)
    return rest[fork.end():] if fork else rest


=======
LEAD = re.compile(
    r"(?:\([^()]*\) && )?vars\.(CI_[A-Z_]+_SKIP_FLEET) != '1' && '(cmux-gcp-[a-z-]+-jit-x64)' \|\| "
)
# The queue-management jobs (sweeps, janitors, rescues) may put one operand before their JIT label: an on switch for
# the reserved queue label, which only they name, so no PR job can take its runners (Leo-ask c-b672a25975: "what do we
# do for ourselves? ... what do we do about this sort of situation?"). Unset, the operand is skipped and the job keeps
# the route it had.
QUEUE_OPERAND = "vars.CI_QUEUE_RESERVED == '1' && 'cmux-gcp-queue-jit-x64' || "
# The same jobs with the switch's value written out: the queue label alone.
QUEUE_LITERAL = FORK_BRANCH + "'cmux-gcp-queue-jit-x64' }}"
# A job whose switch was written out: one literal one-job label after the fork branch.
LITERAL_LEAD = re.compile(r"'(cmux-gcp-[a-z-]+-jit-x64|blacksmith-\dvcpu-ubuntu-2404)' }}$")
QUEUE_LABEL = "cmux-gcp-queue-jit-x64"
QUEUE_WORKFLOWS = frozenset({
    "ci-cla-quota-rerun.yml",
    "ci-hosted-backlog-rescue.yml",
    "ci-hosted-light-rescue.yml",
    "ci-owned-pool-rescue.yml",
    "ci-shed-superseded-runs.yml",
    "ci-stale-run-janitor.yml",
})
# (workflow, line number is not pinned) -> why the job does not lead with a JIT label yet.
EXCEPTIONS = {
    "cla.yml": "the CLA Assistant moves to the gate label with its policy PR (exact-head human approval)",
    "resolve-runners.yml": "the resolver reads no runner variable and must not depend on a fleet it resolves",
    "web-complexity-trusted.yml": "reads untrusted source: only the one-job PR-control JIT label, with no switch a "
    "variable can flip to a pooled overflow route (cmux#49117, test_ci_runner_set)",
}


>>>>>>> origin/main
def marked_jobs() -> list[tuple[str, int, str]]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("runs-on:") and "# ephemeral-required" in stripped:
                found.append((path.name, number, stripped.removeprefix("runs-on:").split(" # ", 1)[0].strip()))
    return found


<<<<<<< HEAD

class WriteTokenJitLabelTests(unittest.TestCase):
    def test_marker_scan_is_not_vacuous(self) -> None:
        self.assertGreater(len(marked_jobs()), 25)

    def test_every_ephemeral_required_job_leads_with_a_jit_label(self) -> None:
        failures = []
        unmoved: dict[str, int] = {}
        for name, number, runs_on in marked_jobs():
            rest = after_fork_branches(runs_on)
            matched = LEAD.match(rest) if rest is not None else None
            if matched is None:
                unmoved[name] = unmoved.get(name, 0) + 1
                if name not in EXCEPTIONS:
                    failures.append(f"{name}:{number} does not lead with a JIT label: {runs_on}")
            elif SWITCHES.get(matched.group(1)) != matched.group(2):
                failures.append(f"{name}:{number} leads with {matched.group(2)} under {matched.group(1)}")
        for name, (count, why) in EXCEPTIONS.items():
            if name in unmoved and unmoved[name] > count:
                failures.append(f"{name}: {unmoved[name]} unmoved marked jobs, {count} excepted ({why})")
        self.assertEqual(failures, [])

    def test_the_exceptions_are_still_needed(self) -> None:
        unmoved: dict[str, int] = {}
        for name, _, runs_on in marked_jobs():
            rest = after_fork_branches(runs_on)
            if rest is None or LEAD.match(rest) is None:
                unmoved[name] = unmoved.get(name, 0) + 1
        for name, (count, _) in EXCEPTIONS.items():
            self.assertEqual(unmoved.get(name, 0), count, f"{name}: update its exception count")

    def test_the_lead_reading_refuses_a_blacksmith_first_selector(self) -> None:
        rest = after_fork_branches(FORK_BRANCH + "contains(fromJSON('[\"blacksmith-4vcpu-ubuntu-2404\"]'), "
                                   "vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}")
        self.assertIsNone(LEAD.match(rest or ""))
=======
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
            if rest is not None and name in QUEUE_WORKFLOWS and rest.startswith(QUEUE_OPERAND):
                rest = rest[len(QUEUE_OPERAND):]
            if rest is not None and rest.startswith("github.event_name == 'pull_request' && "):
                rest = rest.split(" || ", 1)[1]
            if rest is not None and LITERAL_LEAD.fullmatch(rest):
                if QUEUE_LABEL in rest and name not in QUEUE_WORKFLOWS:
                    failures.append(f"{name}:{number} names the reserved queue label")
                continue
            matched = LEAD.match(rest) if rest is not None else None
            if matched is None:
                failures.append(f"{name}:{number} does not lead with a JIT label: {runs_on}")
            elif SWITCHES.get(matched.group(1)) != matched.group(2):
                failures.append(f"{name}:{number} leads with {matched.group(2)} under {matched.group(1)}")
        self.assertEqual(failures, [])

    def test_only_queue_management_jobs_name_the_queue_label(self) -> None:
        named = set()
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                if QUEUE_LABEL not in line:
                    continue
                named.add(path.name)
                self.assertIn(path.name, QUEUE_WORKFLOWS, f"{path.name}:{number} names the reserved queue label")
                self.assertTrue(QUEUE_OPERAND in line or QUEUE_LITERAL in line
                                or line.strip() == "runs-on: " + QUEUE_LABEL,
                                f"{path.name}:{number} names it outside its on switch")
        self.assertEqual(named, QUEUE_WORKFLOWS)

    def test_the_exceptions_are_still_needed(self) -> None:
        names = {name for name, _, _ in marked_jobs()}
        for name in EXCEPTIONS:
            self.assertIn(name, names, f"stale exception {name}")

    def test_the_switch_variables_are_passed_to_the_runs_on_value_check(self) -> None:
        text = (WORKFLOWS / "ci-repo-variables.yml").read_text(encoding="utf-8")
        for variable in (*SWITCHES, "CI_QUEUE_RESERVED"):
            self.assertIn(f"{variable}=${{{{ vars.{variable} }}}}", text)
>>>>>>> origin/main


if __name__ == "__main__":
    unittest.main()
