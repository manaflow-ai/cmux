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
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import workflow_jobs  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
FAILURES = []

# Publishing a commit- or tree-addressed cmux-tui build is not a production
# release: cmux-next builds bundle the daemon of their own cmux-tui tree, and
# helper branches (cmux-tui-pin-*) publish an unmerged branch's tree. Those
# jobs run in the `artifacts` environment (policy: main, feat-cmux-next,
# cmux-tui-pin-*), which holds only the R2 upload credentials.
ARTIFACT_JOBS = {
    "cmux-tui-artifacts.yml": ["publish", "publish-windows", "publish-tree", "publish-tree-tested", "point-feat-channel", "mark-tree-commits"],
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

NIGHTLY_TRACK_ENVIRONMENT = "${{ needs.decide.outputs.environment }}"
NIGHTLY_TRACK_ENVIRONMENT_RULE = "core.setOutput('environment', isNextRef ? 'release-next' : 'release');"
# The jobs after the feed run in the dispatched post-publish run too, where decide skips: the same rule by ref.
NIGHTLY_REF_ENVIRONMENT = "${{ github.ref == 'refs/heads/nightly-next' && 'release-next' || 'release' }}"

RELEASE_JOBS = {
    "release.yml": ["build-sign-notarize"],
    "nightly.yml": ["build-sign-notarize-nightly", "publish-nightly", "publish-nightly-next-github"],
    "ios-app-store.yml": ["upload-and-validate"],
    "ios-testflight.yml": ["set-testflight-notes", "assign-internal-group"],
    "ios-appstore-upload.yml": ["set-testflight-notes", "assign-internal"],
    "repair-v0-64-25-helper-rpaths.yml": ["repair"],
    "repair-nightly-appcast-content-types.yml": ["repair"],
    "update-homebrew.yml": ["update-cask"],
}

# The cmux NEXT feed's own token lives in `release-next` (policy: branch
# nightly-next only).
RELEASE_NEXT_JOBS = {
    "nightly-next-rollback.yml": ["rollback", "pulled-json"],
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
            # The environment's name as written (workflow_jobs.environment_spec: a string or a mapping's `name`).
            environment = (workflow_jobs.environment_spec(definition) or {}).get("name")
            if name == "nightly.yml" and environment == NIGHTLY_TRACK_ENVIRONMENT:
                # nightly.yml picks the environment per track in `decide`:
                # release-next only for branch nightly-next, release otherwise.
                text = open(os.path.join(WORKFLOWS, name), encoding="utf-8").read()
                _check(NIGHTLY_TRACK_ENVIRONMENT_RULE in text,
                       f"{name} {job} environment is release except release-next for nightly-next")
                continue
            if name == "nightly.yml" and environment == NIGHTLY_REF_ENVIRONMENT:
                _check(True, f"{name} {job} environment is release except release-next for nightly-next (by ref)")
                continue
            _check(environment == "release", f"{name} {job} runs in the release environment")
    for name, jobs in RELEASE_NEXT_JOBS.items():
        document = yaml.load(open(os.path.join(WORKFLOWS, name), encoding="utf-8"), Loader=yaml.BaseLoader)
        for job in jobs:
            spec = workflow_jobs.environment_spec(document["jobs"].get(job) or {}) or {}
            _check(spec.get("name") == "release-next",
                   f"{name} {job} runs in the release-next environment")
    for name, jobs in ARTIFACT_JOBS.items():
        text = open(os.path.join(WORKFLOWS, name), encoding="utf-8").read()
        document = yaml.load(text, Loader=yaml.BaseLoader)
        for job in jobs:
            definition = document["jobs"].get(job, {})
            # A mapping keeps the environment and only sets whether it records a deployment.
            _check((workflow_jobs.environment_spec(definition) or {}).get("name") == "artifacts",
                   f"{name} {job} runs in the artifacts environment")
            # Every form GitHub accepts; `secrets: inherit` or a computed index reads ALL_SECRETS, never a subset.
            used = workflow_jobs.secret_names(definition)
            _check(used <= ARTIFACT_SECRETS, f"{name} {job} uses only R2 upload secrets (found {sorted(used)})")
    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)


if __name__ == "__main__":
    main()
