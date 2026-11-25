#!/usr/bin/env python3
"""Jobs that hold production secrets run only from protected refs.

A workflow_dispatch run takes the workflow file and the code from whatever
ref the dispatcher picks, so any condition written in the workflow can be
edited away on a branch. GitHub enforces an environment's deployment branch
policy outside the workflow: these jobs declare the `release` environment
(policy: branch main, tags v*), the artifacts environment, or a cloud-vm environment with its own
policy, and their production secrets live in that environment.

The cmux-cef-write token lives only in `cef-publish` (policy: branch main, no
required reviewer). A workflow with a cef-publish job is dispatch-only: a
pull_request_target, workflow_run or push trigger would run main's file on
input another ref controls, which the branch policy admits. Its first job
refuses any ref but main, and the cef-publish job needs it.

The iroh release gate checks out a requested ref; its job with production
Stack credentials also requires that ref to be the run's own revision.
"""

import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
FAILURES = []

# Publishing a commit-addressed cmux-tui build is not a production release:
# cmux-next pins daemon builds from helper branches (cmux-tui-pin-*). That job
# runs in the `artifacts` environment (policy: main, feat-cmux-next,
# cmux-tui-pin-*), which holds only the R2 upload credentials.
ARTIFACT_JOBS = {
    "cmux-tui-artifacts.yml": ["publish"],
    "dogfood-artifact-publish.yml": ["publish"],
}
ARTIFACT_SECRETS = {
    "CF_R2_ACCESS_KEY_ID",
    "CF_R2_SECRET_ACCESS_KEY",
    "CF_R2_ACCOUNT_ID",
    "CMUX_CEF_R2_ACCESS_KEY_ID",
    "CMUX_CEF_R2_SECRET_ACCESS_KEY",
    "CMUX_CEF_R2_ACCOUNT_ID",
}

RELEASE_JOBS = {
    "release.yml": ["build-sign-notarize"],
    "nightly.yml": ["build-sign-notarize-nightly", "publish-nightly"],
    "ios-app-store.yml": ["upload-and-validate"],
    "ios-appstore-upload.yml": ["set-testflight-notes", "assign-internal"],
    "repair-v0-64-25-helper-rpaths.yml": ["repair"],
    "iroh-release-gate.yml": ["simulator-e2e"],
    "repair-nightly-appcast-content-types.yml": ["repair"],
    "update-homebrew.yml": ["update-cask"],
}

# The cmux NEXT feed's own token lives in `release-next` (policy: branch
# nightly-next only). main carries nightly-next-rollback.yml only so GitHub
# lists it for dispatch; its job runs only on nightly-next.
RELEASE_NEXT_JOBS = {
    "nightly-next-rollback.yml": ["rollback"],
}

# The cmux-cef-write token (CMUX_CEF_R2_WRITE_*) lives only in `cef-publish`
# (deployment branch policy: main). It had required reviewers until Leo asked
# "why do i have to keep approving these???" (2026-11-14): every run was a main
# dispatch, so the reviewer checked nothing the branch policy doesn't. A job in
# any other environment reads it as empty: the Cua Driver SDK publish (run 42278271161) and the dev helper signing asked
# `release` for it and stopped before publishing.
CEF_WRITE_SECRET = re.compile(r"secrets\.CMUX_CEF_R2_WRITE_[A-Z_]+")
CEF_WRITE_ENVIRONMENT = "cef-publish"
# The gate is the whole condition, or its first term joined by && only. A job
# whose own `if` calls always(), cancelled() or failure(), or negates success(),
# runs after a skipped need, so it breaks the chain from the gate.
MAIN_GATE = re.compile(r"^github\.ref == 'refs/heads/main'( && [^|]*)?$")
RUNS_AFTER_SKIP = re.compile(r"\b(always|cancelled|failure)\(|!\s*success\(")


def _condition(definition):
    text = " ".join(str(definition.get("if", "")).split())
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2].strip()
    return text


def _environment(definition):
    environment = definition.get("environment")
    if isinstance(environment, dict):
        environment = environment.get("name")
    return environment


def _needs(definition):
    needs = definition.get("needs") or []
    return [needs] if isinstance(needs, str) else list(needs)


def _main_gated(jobs, job, seen=None):
    """True when job, or a job it needs (transitively), runs only from main."""
    seen = seen if seen is not None else set()
    if job in seen or job not in jobs:
        return False
    seen.add(job)
    condition = _condition(jobs[job])
    if MAIN_GATE.match(condition):
        return True
    if RUNS_AFTER_SKIP.search(condition):
        return False
    return any(_main_gated(jobs, need, seen) for need in _needs(jobs[job]))


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def _gate_cases():
    """_main_gated on hand-made jobs: a status condition that runs after a skipped gate breaks the chain."""
    gate = {"if": "github.ref == 'refs/heads/main'"}
    for condition, expected in (
        ("", True),
        ("success()", True),
        ("always()", False),
        ("!cancelled()", False),
        ("failure()", False),
        ("!success()", False),
        ("${{ ! success() }}", False),
    ):
        jobs = {"resolve": gate, "publish": {"needs": "resolve", "if": condition}}
        _check(_main_gated(jobs, "publish") is expected,
               f"publish with if {condition!r} after a main gate: main-gated is {expected}")


def main():
    _gate_cases()
    for name, jobs in RELEASE_JOBS.items():
        document = yaml.load(open(os.path.join(WORKFLOWS, name), encoding="utf-8"), Loader=yaml.BaseLoader)
        for job in jobs:
            definition = document["jobs"].get(job, {})
            _check(definition.get("environment") == "release", f"{name} {job} runs in the release environment")
    for name, jobs in RELEASE_NEXT_JOBS.items():
        document = yaml.load(open(os.path.join(WORKFLOWS, name), encoding="utf-8"), Loader=yaml.BaseLoader)
        for job in jobs:
            _check(document["jobs"].get(job, {}).get("environment") == "release-next",
                   f"{name} {job} runs in the release-next environment")
    for name, jobs in ARTIFACT_JOBS.items():
        text = open(os.path.join(WORKFLOWS, name), encoding="utf-8").read()
        document = yaml.load(text, Loader=yaml.BaseLoader)
        for job in jobs:
            definition = document["jobs"].get(job, {})
            _check(definition.get("environment") == "artifacts", f"{name} {job} runs in the artifacts environment")
            used = set(re.findall(r"secrets\.([A-Za-z0-9_]+)", yaml.dump(definition)))
            _check(used <= ARTIFACT_SECRETS, f"{name} {job} uses only R2 upload secrets (found {sorted(used)})")
    for name in sorted(os.listdir(WORKFLOWS)):
        if not name.endswith((".yml", ".yaml")):
            continue
        document = yaml.load(open(os.path.join(WORKFLOWS, name), encoding="utf-8"), Loader=yaml.BaseLoader)
        for job, definition in ((document or {}).get("jobs") or {}).items():
            environment = _environment(definition)
            if CEF_WRITE_SECRET.search(yaml.dump(definition)):
                _check(environment == CEF_WRITE_ENVIRONMENT,
                       f"{name} {job} reads the cmux-cef-write token from the {CEF_WRITE_ENVIRONMENT} environment")
            if environment == CEF_WRITE_ENVIRONMENT:
                triggers = document.get("on")
                triggers = [triggers] if isinstance(triggers, str) else list(triggers or [])
                _check(triggers == ["workflow_dispatch"],
                       f"{name} runs {CEF_WRITE_ENVIRONMENT} only on workflow_dispatch (found {triggers})")
                _check(_main_gated(document["jobs"], job),
                       f"{name} {job} needs a job that runs only from refs/heads/main")
    gate = yaml.load(open(os.path.join(WORKFLOWS, "iroh-release-gate.yml"), encoding="utf-8"), Loader=yaml.BaseLoader)
    condition = " ".join(str(gate["jobs"]["simulator-e2e"].get("if", "")).split())
    _check(
        condition == "${{ needs.resolve-ref.outputs.sha == github.sha }}",
        "iroh-release-gate simulator-e2e runs only the run's own revision",
    )
    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)


if __name__ == "__main__":
    main()
