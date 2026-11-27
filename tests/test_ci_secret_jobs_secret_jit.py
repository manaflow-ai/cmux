"""Every Linux job that holds a secret leads with a one-job GCP JIT label.

A secret here means one of three things:
- a `secrets.X` other than GITHUB_TOKEN;
- a `create-github-app-token` step;
- a signing step.

Blacksmith labels and hosted Ubuntu labels are also registered by the persistent runner pool. So a job that names one
first can land on a shared, reused VM, where its secret could outlive the job. The JIT labels
(cmuxterm-hq runner_pool.py JIT_ONLY_LABELS) are served only by VMs the fleet boots for one queued job and deletes
after it.

So after the fork branch (a fork keeps the literal 'ubuntu-24.04'), and after any fork-PR clause that yields
'ubuntu-24.04', the runs-on chain must yield a cmux-gcp-*-jit-x64 label first. On main no Linux `runs-on` reads a
variable (#53905), so the jobs moved here name the label literally: `<fork branch> || 'cmux-gcp-secret-jit-x64' }}`.
Jobs that already led with their own JIT label (repair, PR control, gate, nightly, queue) keep it.

EXCEPTIONS lists the jobs that stay where they are, each with its reason. The test also fails when an exception is no
longer needed.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
SECRET_JIT_LABEL = "cmux-gcp-secret-jit-x64"  # cmuxterm-hq runner_pool.py SECRET_JIT_LABEL
FORK_BRANCH = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
SECRET = re.compile(r"secrets\.(?!GITHUB_TOKEN\b)[A-Za-z_]+|create-github-app-token|secrets\[")
SIGN = re.compile(r"\b(cosign|minisign|gpg --|signtool|sign_update|SIGNING_KEY|PRIVATE_KEY)\b")
LINUX = re.compile(r"blacksmith|ubuntu|cmux-gcp|linux", re.I)
MAC = re.compile(r"macos|cmux-mac", re.I)
JIT_LABEL = re.compile(r"'cmux-gcp-[a-z-]+-jit-x64'")
LABEL_LITERAL = re.compile(r"'([a-z0-9][a-z0-9.-]*)'")

LEO_OVERFLOW = "Leo's #49325: main jobs ask for cmux-linux behind the CI_OVERFLOW_LINUX switch"
EXCEPTIONS = {
    ("cla.yml", "CLAAssistant"): "pull_request_target CLA job; #48564 owns its runner",
    ("cla-policy-guard.yml", "validate"): "pull_request_target CLA job; #48564 owns its runner",
    ("sdk-bootstrap-npm.yml", "publish"): "npm provenance publishing needs a GitHub-hosted runner",
    ("fast-checks.yml", "admit"): "PR fast-checks admission: the broker re-dispatches it after 180 s with no runner, "
    "inside a JIT VM's boot; tests/test_ci_fork_runner_routing.py pins its exact expression",
    ("ci-queue-janitor.yml", "sweep"): "queue janitor's own CI_QUEUE_JANITOR_ON_FLEET route; defaults to repair JIT",
    ("ci-queue-janitor-watchdog.yml", "watch"): "queue janitor's own CI_QUEUE_JANITOR_ON_FLEET route",
    ("ci-cloud-overflow-probe.yml", "watch"): "the overflow watch flips routing when the fleet stalls, so it may not "
    "wait on a fleet VM; main pins its frozen label (tests/test_ci_cloud_overflow_switch.py WATCH_FROZEN)",
    ("ci-main-full-suite.yml", "dispatch"): LEO_OVERFLOW,
    ("cmux-next-ios-kit.yml", "start"): LEO_OVERFLOW,
    ("first-user-journey-ios.yml", "start"): LEO_OVERFLOW,
    ("ios-reliability-matrix.yml", "start"): LEO_OVERFLOW,
    ("nightly-next-health.yml", "start"): LEO_OVERFLOW,
    ("real-login-canaries.yml", "dispatch"): LEO_OVERFLOW,
    ("stable-next.yml", "tick"): LEO_OVERFLOW,
}


def top_level_operands(expression: str) -> list[str]:
    """EXPRESSION split on its top-level `||`, outside parentheses and quotes."""
    operands, depth, quoted, start, index = [], 0, False, 0, 0
    while index < len(expression):
        char = expression[index]
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
        elif not quoted and depth == 0 and expression.startswith("||", index):
            operands.append(expression[start:index].strip())
            index += 2
            start = index
            continue
        index += 1
    operands.append(expression[start:].strip())
    return operands


def secret_linux_jobs():
    """(file, job id, runs-on) for each Linux job that holds a secret, mints an App token or signs."""
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text())
        if not isinstance(document, dict):
            continue
        top_env = yaml.safe_dump(document.get("env") or {})
        for job_id, job in (document.get("jobs") or {}).items():
            if not isinstance(job, dict) or "uses" in job:
                continue
            runs_on = job.get("runs-on")
            if not isinstance(runs_on, str) or not LINUX.search(runs_on) or MAC.search(runs_on):
                continue
            body = yaml.safe_dump(job)
            if SECRET.search(body) or SECRET.search(top_env) or SIGN.search(body):
                yield path.name, job_id, runs_on


def leads_with_jit(runs_on: str) -> bool:
    """True when RUNS_ON is a JIT label, or its first operand after the fork and fork-PR branches yields one."""
    if runs_on.strip() == SECRET_JIT_LABEL:
        return True
    if not runs_on.startswith(FORK_BRANCH) or not runs_on.rstrip().endswith("}}"):
        return False
    operands = top_level_operands(runs_on[len(FORK_BRANCH):].rstrip()[:-2])
    while operands and LABEL_LITERAL.findall(operands[0]) == ["ubuntu-24.04"] and operands[0] != "'ubuntu-24.04'":
        operands.pop(0)  # a fork-PR clause: `<conditions> && 'ubuntu-24.04'`
    if len(operands) == 1:
        return bool(JIT_LABEL.fullmatch(operands[0]))  # the literal form: no variable can move the job
    labels = LABEL_LITERAL.findall(operands[0])
    yielded = labels[-1] if labels else ""
    return bool(JIT_LABEL.fullmatch(f"'{yielded}'")) and operands[0].endswith(f"'{yielded}'")


class SecretJobsSecretJitTest(unittest.TestCase):
    def test_secret_linux_jobs_lead_with_a_jit_label(self) -> None:
        offenders = [f"{name} {job}: {runs_on}" for name, job, runs_on in secret_linux_jobs()
                     if (name, job) not in EXCEPTIONS and not leads_with_jit(runs_on)]
        self.assertEqual(offenders, [], "secret-bearing Linux jobs must name "
                         f"'{SECRET_JIT_LABEL}' after the fork branch")

    def test_exceptions_are_still_needed(self) -> None:
        jobs = {(name, job): runs_on for name, job, runs_on in secret_linux_jobs()}
        stale = [key for key in EXCEPTIONS if key not in jobs or leads_with_jit(jobs[key])]
        self.assertEqual(stale, [], "remove these EXCEPTIONS entries")

    def test_detector(self) -> None:
        fork_pr = "github.event_name == 'pull_request' && github.event.pull_request.head.repo.fork && 'ubuntu-24.04' || "
        operand = f"vars.CI_SECRET_SKIP_FLEET != '1' && '{SECRET_JIT_LABEL}' || "
        self.assertTrue(leads_with_jit(FORK_BRANCH + operand + "'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertTrue(leads_with_jit(FORK_BRANCH + fork_pr + operand + "'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertTrue(leads_with_jit(
            FORK_BRANCH + "github.run_attempt == 1 && 'cmux-gcp-nightly-jit-x64' || 'blacksmith-2vcpu-ubuntu-2404' }}"))
        self.assertTrue(leads_with_jit(FORK_BRANCH + f"'{SECRET_JIT_LABEL}' }}}}"))
        self.assertFalse(leads_with_jit(FORK_BRANCH + "'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertFalse(leads_with_jit("blacksmith-4vcpu-ubuntu-2404"))
        self.assertFalse(leads_with_jit("ubuntu-24.04"))
        self.assertFalse(leads_with_jit(FORK_BRANCH + "'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertFalse(leads_with_jit(FORK_BRANCH + "vars.LINUX_RUNNER || 'cmux-gcp-secret-jit-x64' }}"))
        self.assertFalse(leads_with_jit(
            "${{ " + operand + "'blacksmith-4vcpu-ubuntu-2404' }}"))  # no fork branch
        self.assertFalse(leads_with_jit(
            FORK_BRANCH + "vars.X != '1' && 'cmux-fleet-linux-x64' || 'cmux-gcp-repair-jit-x64' }}"))


if __name__ == "__main__":
    unittest.main()
