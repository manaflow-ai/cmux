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
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
FORK_BRANCH = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
FORK_PR = re.compile(r"(?:github\.event_name == 'pull_request' && )?github\.event\.pull_request\.head\.repo\.full_name "
                     r"!= github\.repository && 'blacksmith-[0-9]+vcpu-ubuntu-2404' \|\| ")
# switch variable -> the one JIT label it may turn off
SWITCHES = {
    "CI_REPAIR_SKIP_FLEET": "cmux-gcp-repair-jit-x64",
    "CI_PR_CONTROL_SKIP_FLEET": "cmux-gcp-pr-control-jit-x64",
    "CI_GATE_SKIP_FLEET": "cmux-gcp-gate-jit-x64",
}
LEAD = re.compile(r"(?:\([^()]*\) && )?vars\.(CI_[A-Z_]+_SKIP_FLEET) != '1' && '(cmux-gcp-[a-z-]+-jit-x64)' \|\| ")
# workflow -> (marked lines that do not lead with a JIT label yet, why). A count, so a new unmoved job still fails.
EXCEPTIONS = {
    "backend-migrations.yml": (4, "the required migration checks move to the gate label with their own policy PR, as on main"),
    "pr-checks.yml": (1, "the advisory comment job left the PR control label when it backed up (tests/test_ci_runner_set.py)"),
    "pr-red-checks-comment.yml": (1, "the status comment job takes the same CI_TRUSTED_RUNNER selector as pr-checks.yml's; cmux-linux queued it 5-7 min"),
    "cmux-next.yml": (2, "the push/PR control arms (tests/test_cmux_next_pr_control_on_jit.py)"),
    "machine-vault-e2e.yml": (1, "a macOS job (adds a macOS user as root): no GCP Linux JIT label can run it"),
    "relay-tls.yml": (1, "a macOS job (adds a System keychain trust root): no GCP Linux JIT label can run it"),
    "ios-asc-subscription-records.yml": (1, "leads with the one-job nightly JIT label on the first attempt, the Linux pool on a retry; no skip switch"),
}


def after_fork_branches(runs_on: str) -> str | None:
    if not runs_on.startswith(FORK_BRANCH):
        return None
    rest = runs_on[len(FORK_BRANCH):]
    fork = FORK_PR.match(rest)
    return rest[fork.end():] if fork else rest


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


if __name__ == "__main__":
    unittest.main()
