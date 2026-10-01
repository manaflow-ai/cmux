#!/usr/bin/env python3
"""Jobs that hold production secrets run only from protected refs.

A workflow_dispatch run takes the workflow file and the code from whatever
ref the dispatcher picks, so any condition written in the workflow can be
edited away on a branch. GitHub enforces an environment's deployment branch
policy outside the workflow: these jobs declare the `release` environment
(policy: branch main, tags v*), the artifacts environment, or a cloud-vm environment with its own
policy, and their production secrets live in that environment.

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
}
ARTIFACT_SECRETS = {"CF_R2_ACCESS_KEY_ID", "CF_R2_SECRET_ACCESS_KEY", "CF_R2_ACCOUNT_ID"}

RELEASE_JOBS = {
    "release.yml": ["build-sign-notarize"],
    "nightly.yml": ["build-sign-notarize-nightly", "publish-nightly"],
    "ios-app-store.yml": ["upload-and-validate"],
    "ios-testflight.yml": ["set-testflight-notes", "assign-internal-group"],
    "ios-appstore-upload.yml": ["set-testflight-notes", "assign-internal"],
    "repair-v0-64-25-helper-rpaths.yml": ["repair"],
    "iroh-release-gate.yml": ["simulator-e2e"],
    "repair-nightly-appcast-content-types.yml": ["repair"],
    "update-homebrew.yml": ["update-cask"],
}


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def main():
    for name, jobs in RELEASE_JOBS.items():
        document = yaml.load(open(os.path.join(WORKFLOWS, name), encoding="utf-8"), Loader=yaml.BaseLoader)
        for job in jobs:
            definition = document["jobs"].get(job, {})
            _check(definition.get("environment") == "release", f"{name} {job} runs in the release environment")
    for name, jobs in ARTIFACT_JOBS.items():
        text = open(os.path.join(WORKFLOWS, name), encoding="utf-8").read()
        document = yaml.load(text, Loader=yaml.BaseLoader)
        for job in jobs:
            definition = document["jobs"].get(job, {})
            _check(definition.get("environment") == "artifacts", f"{name} {job} runs in the artifacts environment")
            used = set(re.findall(r"secrets\.([A-Za-z0-9_]+)", yaml.dump(definition)))
            _check(used <= ARTIFACT_SECRETS, f"{name} {job} uses only R2 upload secrets (found {sorted(used)})")
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
