#!/usr/bin/env python3
"""nightly-sign.yml in shadow mode cannot sign, notarize or publish (no network).

nightly-sign.yml runs from main on every completed "Nightly macOS build" run
(cmuxterm-hq#2053). Until the comparison runs are done it must stay inert:

- every job is gated `vars.NIGHTLY_SIGN == 'shadow' && (...)`, so with the
  variable unset (the default) or set to any other value no job runs;
- a shadow job holds no environment and no secret, asks only for read
  permissions, runs on literal Linux labels, no variable (no keychain), checks
  out only main (no `ref`, no `repository`), uses no action but checkout,
  has no container, services, defaults or shell override, and runs exactly
  one fixed command: main's admit tool. So no signing, notary or publish
  step exists;
- the admit tool starts no process and unpacks no tarball;
- no job is gated on another mode yet (the step that adds signing jobs must
  change this test on purpose);
- nightly.yml does not read vars.NIGHTLY_SIGN, so shadow mode cannot change
  the current signing and publication path;
- nightly.yml's prepare job records the digest the admit tool reads, with the
  same artifact name it uploads.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly-sign.yml"
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"
TOOL = ROOT / "scripts" / "ci" / "nightly_sign_admit.py"
sys.path.insert(0, str(TOOL.parent))

import nightly_sign_admit  # noqa: E402

SHADOW_GATE = "vars.NIGHTLY_SIGN == 'shadow' && ("
CHECKOUT = re.compile(r"^actions/checkout@[0-9a-f]{40}$")
READ_PERMISSIONS = {"actions", "checks", "contents"}
ADMIT_COMMAND = (
    'python3 -I scripts/ci/nightly_sign_admit.py --repo "$GITHUB_REPOSITORY" '
    '--source-run-id "$SOURCE_RUN_ID" --source-run-attempt "$SOURCE_RUN_ATTEMPT" '
    '--out "$RUNNER_TEMP/nightly-sign-source"'
)
# Literal labels only (no variable moves the job): Blacksmith Linux, a fork the hosted image.
LINUX_RUNNER = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}"
JOB_KEYS = {"name", "if", "runs-on", "timeout-minutes", "permissions", "steps"}
STEP_KEYS = {"name", "id", "uses", "with", "env", "run"}
WORKFLOW_KEYS = {"name", "on", True, "permissions", "env", "concurrency", "jobs"}
# Expression contexts a shadow job may read. Nothing that names the source
# run's ref, commit or pull requests: the tool reads those from the API.
ALLOWED_CONTEXTS = re.compile(
    r"^(github\.token|github\.ref|github\.event_name|github\.repository_owner|"
    r"github\.event\.workflow_run\.(id|run_attempt|conclusion)|"
    r"inputs\.source_run_(id|attempt)|vars\.NIGHTLY_SIGN)$"
)
FORBIDDEN_IN_TOOL = re.compile(
    r"\b(subprocess|os\.system|os\.exec\w*|os\.spawn\w*|popen|tarfile|extractall|codesign|notary\w*|"
    r"stapler|keychain|upload|release)\b",
    re.IGNORECASE,
)

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def triggers(document: dict) -> dict:
    on = document.get("on", document.get(True))
    return on if isinstance(on, dict) else {}


def gate_is_shadow_conjunct(expression: str) -> bool:
    """`vars.NIGHTLY_SIGN == 'shadow' && ( ... )` with the group closing at the end."""
    expression = " ".join(expression.split())
    if not expression.startswith(SHADOW_GATE) or not expression.endswith(")"):
        return False
    depth = 0
    body = expression[len(SHADOW_GATE) - 1:]
    for index, char in enumerate(body):
        depth += char == "("
        depth -= char == ")"
        if depth == 0 and index != len(body) - 1:
            return False
    return depth == 0


def contexts(text: str) -> set[str]:
    found: set[str] = set()
    for expression in re.findall(r"\$\{\{(.*?)\}\}", text, re.DOTALL):
        found.update(re.findall(r"\b(?:github|inputs|vars|secrets|env|steps|needs|matrix|runner|job)\.[A-Za-z0-9_.]+", expression))
    return found


def check_workflow() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    document = yaml.safe_load(text)
    on = triggers(document)
    workflow_run = on.get("workflow_run") or {}
    check(workflow_run.get("workflows") == ["Nightly macOS build"], "nightly-sign.yml must trigger on Nightly macOS build only")
    check(workflow_run.get("types") == ["completed"], "nightly-sign.yml must trigger on completed runs")
    check(set(on) <= {"workflow_run", "workflow_dispatch"}, f"nightly-sign.yml has extra triggers: {sorted(on)}")
    check(document.get("permissions") == {}, "nightly-sign.yml must grant no workflow-level permissions")
    check(not re.search(r"\bsecrets\b", text), "nightly-sign.yml must not name secrets in any form")
    check(set(document) <= WORKFLOW_KEYS, f"nightly-sign.yml has unexpected top-level keys {sorted(map(str, document))}")
    check(set(document.get("env") or {}) == {"SOURCE_WORKFLOW_PATHS"}, "nightly-sign.yml workflow env holds only SOURCE_WORKFLOW_PATHS")
    check("NIGHTLY_SIGN" in text, "nightly-sign.yml must be gated on vars.NIGHTLY_SIGN")
    check(document.get("env", {}).get("SOURCE_WORKFLOW_PATHS") == ".github/workflows/nightly.yml",
          "nightly-sign.yml must declare SOURCE_WORKFLOW_PATHS")

    jobs = document.get("jobs") or {}
    check(bool(jobs), "nightly-sign.yml has no jobs")
    for job_id, job in jobs.items():
        where = f"nightly-sign.yml job {job_id}"
        check(set(job) <= JOB_KEYS, f"{where}: only {sorted(JOB_KEYS)} are allowed (got {sorted(job)})")
        gate = str(job.get("if", ""))
        check(gate_is_shadow_conjunct(gate),
              f"{where}: `if` must be `{SHADOW_GATE}...)` so an unset NIGHTLY_SIGN runs nothing (got {gate!r}); "
              "a job for another mode needs this test changed on purpose")
        check("environment" not in job, f"{where}: a shadow job must not use an environment")
        check("secrets" not in job, f"{where}: a shadow job must not take secrets")
        permissions = job.get("permissions")
        check(isinstance(permissions, dict) and set(permissions) <= READ_PERMISSIONS
              and set(permissions.values()) == {"read"},
              f"{where}: permissions must be read-only actions/checks/contents (got {permissions!r})")
        check(job.get("runs-on") == LINUX_RUNNER, f"{where}: a shadow job runs on literal Linux labels ({LINUX_RUNNER})")
        for name in contexts(yaml.safe_dump(job)) | contexts("${{ " + gate + " }}"):
            check(bool(ALLOWED_CONTEXTS.match(name)), f"{where}: reads {name}, which a shadow job must not use")
        steps = job.get("steps") or []
        check(bool(steps), f"{where}: has no steps")
        ran_admit = False
        for step in steps:
            label = f"{where} step {step.get('name', '?')!r}"
            check(set(step) <= STEP_KEYS, f"{label}: only {sorted(STEP_KEYS)} are allowed (got {sorted(step)})")
            uses = step.get("uses")
            if uses is not None:
                check(bool(CHECKOUT.match(str(uses))), f"{label}: only a pinned actions/checkout may run (got {uses})")
                options = step.get("with") or {}
                check(set(options) <= {"persist-credentials", "submodules"},
                      f"{label}: checkout must take main's default ref (got {sorted(options)})")
                check(options.get("persist-credentials") is False, f"{label}: checkout must not persist credentials")
                continue
            run = " ".join(str(step.get("run", "")).split())
            check(run == ADMIT_COMMAND, f"{label}: the only command a shadow job runs is exactly main's admit tool (got {run!r})")
            ran_admit = ran_admit or run == ADMIT_COMMAND
        check(ran_admit, f"{where}: does not run the admit tool")


def check_tool() -> None:
    source = TOOL.read_text(encoding="utf-8")
    code = "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("#"))
    code = re.sub(r'"""(?:.|\n)*?"""', "", code)
    for match in FORBIDDEN_IN_TOOL.finditer(code):
        failures.append(f"scripts/ci/nightly_sign_admit.py: uses {match.group(0)!r}; the admit tool runs and unpacks nothing")


def check_nightly_producer() -> None:
    text = NIGHTLY.read_text(encoding="utf-8")
    check("NIGHTLY_SIGN" not in text, "nightly.yml must not read vars.NIGHTLY_SIGN while nightly-sign.yml is in shadow mode")
    steps = yaml.safe_load(text)["jobs"]["prepare-nightly-variant"]["steps"]
    names = [step.get("name") for step in steps]
    try:
        package = names.index("Package prepared app for signing")
        record = names.index("Record prepared app digest")
        upload = names.index("Upload prepared app for signing")
    except ValueError as error:
        failures.append(f"nightly.yml prepare-nightly-variant: {error}")
        return
    check(package < record < upload, "nightly.yml prepare-nightly-variant must record the digest after packaging and before upload")
    record_step, upload_step = steps[record], steps[upload]
    check(record_step["env"]["PREPARED_APP_ARTIFACT"] == upload_step["with"]["name"],
          "nightly.yml must record the digest under the artifact name it uploads")
    check(upload_step["with"]["path"] == f"prepared-app-handoff/{nightly_sign_admit.TARBALL}",
          "nightly.yml must upload exactly the tarball the admit tool hashes")
    run = record_step["run"]
    check(f"shasum -a 256 prepared-app-handoff/{nightly_sign_admit.TARBALL}" in run,
          "nightly.yml must hash the uploaded tarball")
    echo = (
        f"::notice title={nightly_sign_admit.DIGEST_TITLE}::variant=${{NIGHTLY_VARIANT}} artifact=${{PREPARED_APP_ARTIFACT}} "
        "sha256=${digest} publish=${NIGHTLY_SHOULD_PUBLISH} fast=${NIGHTLY_FAST_BUILD}"
    )
    check(echo in run, "nightly.yml must record the digest in the format the admit tool parses")
    check(record_step["env"].get("NIGHTLY_SHOULD_PUBLISH") == "${{ needs.decide.outputs.should_publish }}",
          "nightly.yml must record decide's should_publish")
    sample = "variant=arm64 artifact=cmux-nightly-prepared-app-arm64-cc2280f sha256=" + "a" * 64 + " publish=true fast=false"
    check(bool(nightly_sign_admit.DIGEST_MESSAGE.match(sample)), "the admit tool must parse the recorded format")


def main() -> int:
    check_workflow()
    check_tool()
    check_nightly_producer()
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("nightly-sign.yml shadow mode: no signing, notary or publish step; gated off by default")
    return 0


if __name__ == "__main__":
    sys.exit(main())
