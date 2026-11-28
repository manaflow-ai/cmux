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
# A signing step: a signing tool, a gpg/openssl/ssh-keygen signing flag, or a signing key, certificate or password.
# An identity name alone (CMUX_DEV_SIGN_IDENTITY picks ad hoc signing) is not a secret.
SIGN = re.compile(
    r"\b(?:cosign|minisign|signtool|sign_update|codesign|notarytool|apksigner|jarsigner|rcodesign|osslsigncode)\b"
    r"|\bgpg\b[^\n]*?(?:--(?:detach-|clear)?sign\b|\s-[a-z]*s[a-z]*b?\b)"
    r"|\bopenssl\s+(?:dgst|pkeyutl|smime|cms)\b[^\n]*?-sign\b|\bssh-keygen\b[^\n]*?-Y\s+sign\b"
    r"|\b[A-Z0-9_]*(?:SIGNING|_SIGN)_?(?:KEY|CERT|CERTIFICATE|PASSWORD|PASSPHRASE|P12)(?:_[A-Z0-9]+)*\b"
    r"|\b[A-Z0-9_]*PRIVATE_KEY\b|\b[A-Z0-9_]*_P12(?:_[A-Z0-9_]+)?\b")
# A Linux runner label: hosted and Blacksmith Ubuntu, the GCP fleet, cmux-linux, or a RUNNER_POOLS linux key.
LINUX_LABEL = re.compile(r"ubuntu-[0-9a-z.]+|blacksmith-\d+vcpu-ubuntu-\d+(?:-arm)?|cmux-gcp-[a-z0-9-]+-x64"
                         r"|cmux-linux|cmux-fleet-linux(?:-[a-z0-9-]+)?")
LINUX_POOL = re.compile(r"fromJSON\(vars\.RUNNER_POOLS\)\.linux_\w+")
# A Mac selector: macOS labels, the owned glaeda Macs, or the CI_NIGHTLY_* Mac runner variables.
MAC = re.compile(r"macos|cmux-mac|glaeda-|vars\.CI_NIGHTLY_(?:MINI|SIGN_RUNNER|ONLY_RUNNER)\b", re.I)
SKIP_SWITCH = f"vars.CI_SECRET_SKIP_FLEET != '1' && '{SECRET_JIT_LABEL}'"
JIT_LABEL = re.compile(r"'cmux-gcp-[a-z-]+-jit-x64'")
LABEL_LITERAL = re.compile(r"'([a-z0-9][a-z0-9.-]*)'")

AD_HOC_SIGN = ("runs rcodesign/codesign ad hoc and holds no secret; it stays on Leo's #49325 CI_OVERFLOW_LINUX "
               "route")
LEO_OVERFLOW = "Leo's #49325: main jobs ask for cmux-linux behind the CI_OVERFLOW_LINUX switch"
PR_GATE = ("gates every same-repo PR's CI; its only secrets are continue-on-error routing and read-token mints, so it "
           "stays on its warm selector rather than wait 1-2 min for a one-job JIT VM")
# Jobs every same-repo PR waits on before its CI starts. They keep their warm selector (#58325 review, F1).
PR_GATE_JOBS = (
    ("ci.yml", "changes"),
    ("ci-macos.yml", "admission-placement"),
    ("ci-macos.yml", "late-placement"),
)
EXCEPTIONS = {
    **{job: PR_GATE for job in PR_GATE_JOBS},
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
    **{job: AD_HOC_SIGN for job in (("ci-guards.yml", "workflow-guard-tests"), ("cmux-next-dev-daily.yml", "rcodesign"),
                                    ("cmux-next-dev-daily.yml", "drop-signed-handoff"),
                                    ("rcodesign-parity-proof.yml", "rcodesign"),
                                    ("rcodesign-parity-proof.yml", "compare"))},
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


def owner_selector(runs_on: str) -> str:
    """RUNS_ON without the fork branch, fork-PR clauses and the secret JIT switch: the labels the owner's own runs ask for.

    The fork branch's 'ubuntu-24.04' never runs on the owner's repo, so a Mac job's fork branch must not make it Linux.
    """
    if not runs_on.startswith(FORK_BRANCH) or not runs_on.rstrip().endswith("}}"):
        return runs_on
    operands = top_level_operands(runs_on[len(FORK_BRANCH):].rstrip()[:-2])
    while len(operands) > 1 and (operands[0] == SKIP_SWITCH or (
            LABEL_LITERAL.findall(operands[0]) == ["ubuntu-24.04"] and operands[0] != "'ubuntu-24.04'")):
        operands.pop(0)
    return "${{ " + " || ".join(operands) + " }}"


def is_mac(runs_on: str) -> bool:
    """True when the owner's selector names a Mac label or a CI_NIGHTLY_* Mac runner variable."""
    return bool(MAC.search(owner_selector(runs_on)))


def runner_labels(runs_on: str) -> list[str]:
    """The label literals RUNS_ON can yield: its quoted literals, or the bare label itself."""
    return LABEL_LITERAL.findall(runs_on) if "${{" in runs_on else [runs_on.strip()]


def is_linux(runs_on: str) -> bool:
    """True when RUNS_ON names a Linux runner label or a RUNNER_POOLS linux pool, not just the word linux."""
    owner = owner_selector(runs_on)
    return not is_mac(runs_on) and (
        any(LINUX_LABEL.fullmatch(label) for label in runner_labels(owner)) or bool(LINUX_POOL.search(owner)))


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
            if not isinstance(runs_on, str) or not is_linux(runs_on):
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
    maxDiff = None
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


    def test_pr_gate_jobs_stay_warm(self) -> None:
        """A PR-gate job must not wait for a JIT VM's boot, and its secret steps must stay optional."""
        jobs = {(name, job): runs_on for name, job, runs_on in secret_linux_jobs()}
        for key in PR_GATE_JOBS:
            self.assertIn(key, jobs, f"{key} is no longer a secret-bearing Linux job; drop it from PR_GATE_JOBS")
            self.assertFalse(leads_with_jit(jobs[key]), f"{key} gates every PR: keep it on its warm selector")
            self.assertNotIn(SECRET_JIT_LABEL, jobs[key], f"{key} gates every PR: keep it off {SECRET_JIT_LABEL}")
            document = yaml.safe_load((WORKFLOWS / key[0]).read_text())
            for step in document["jobs"][key[1]].get("steps") or []:
                if SECRET.search(yaml.safe_dump(step)) or SIGN.search(yaml.safe_dump(step)):
                    self.assertIs(step.get("continue-on-error"), True,
                                  f"{key} step {step.get('name')!r} holds a secret the gate needs; move the job to JIT")

    def test_mac_jobs_stay_off_the_jit_label(self) -> None:
        offenders = []
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            document = yaml.safe_load(path.read_text())
            for job_id, job in ((document or {}).get("jobs") or {}).items() if isinstance(document, dict) else ():
                runs_on = job.get("runs-on") if isinstance(job, dict) else None
                if isinstance(runs_on, str) and is_mac(runs_on) and SECRET_JIT_LABEL in runs_on:
                    offenders.append(f"{path.name} {job_id}")
        self.assertEqual(offenders, [], f"Mac jobs must not lead with the Linux {SECRET_JIT_LABEL} label")

    def test_mac_selectors_are_not_linux(self) -> None:
        for owner in ("vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_MINI || vars.CI_NIGHTLY_ONLY_RUNNER || "
                      "'glaeda-nightly-only-m4pro'", "vars.CI_NIGHTLY_SIGN_RUNNER || 'glaeda-nightly-std-xcode-26.6'",
                      "'macos-15'", "'cmux-mac-arm64'"):
            self.assertFalse(is_linux(FORK_BRANCH + owner + " }}"), owner)
            self.assertFalse(is_linux(FORK_BRANCH + SKIP_SWITCH + " || " + owner + " }}"), owner)
            self.assertTrue(is_mac(FORK_BRANCH + SKIP_SWITCH + " || " + owner + " }}"), owner)
        self.assertTrue(is_linux(FORK_BRANCH + SKIP_SWITCH + " || 'cmux-linux' }}"))
        self.assertTrue(is_linux(FORK_BRANCH + f"'{SECRET_JIT_LABEL}' }}}}"))

    def test_linux_matches_a_runner_label(self) -> None:
        self.assertTrue(is_linux("blacksmith-4vcpu-ubuntu-2404"))
        self.assertTrue(is_linux(FORK_BRANCH + "'cmux-linux' }}"))
        self.assertTrue(is_linux("${{ fromJSON(vars.RUNNER_POOLS).linux_4 }}"))
        # The word linux in a variable or expression is not a Linux label.
        self.assertFalse(is_linux("${{ vars.CI_OVERFLOW_LINUX == '1' && 'windows-2025' || 'windows-latest' }}"))
        self.assertFalse(is_linux("${{ needs.plan.outputs.linux_runner }}"))

    def test_sign_matches_signing_steps(self) -> None:
        for step in ("codesign --force --sign \"$IDENTITY\" cmux", "xcrun notarytool submit cmux.zip",
                     "gpg --batch --detach-sign SHA256SUMS", "gpg -abs SHA256SUMS",
                     "openssl dgst -sha256 -sign key.pem -out sig bin", "ssh-keygen -Y sign -f key -n file x",
                     "APPLE_SIGNING_CERT_PASSWORD: x", "MACOS_CERTIFICATE_P12: x", "TAURI_SIGNING_PRIVATE_KEY: x"):
            self.assertTrue(SIGN.search(step), step)
        # Words that only contain "sign" are not signing steps.
        for step in ("echo design assignment signal", "gpg --verify SHA256SUMS.asc", "git commit --signoff",
                     "openssl dgst -sha256 file", "SIGNAL_TIMEOUT: 5",
                     "signs ad hoc unless CMUX_DEV_SIGN_IDENTITY names an identity"):
            self.assertFalse(SIGN.search(step), step)



if __name__ == "__main__":
    unittest.main()
