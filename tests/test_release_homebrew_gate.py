#!/usr/bin/env python3
"""The Homebrew cask update must depend on the signed macOS build, not the run.

release.yml runs `generate-ios-screenshots` alongside `build-sign-notarize` and
says so explicitly: the DMG consumes nothing from it, and "a slow or flaky
simulator capture must neither delay nor fail a macOS release" (issue #12149).
The capture still turns the run red so it stays visible.

update-homebrew.yml used to gate on `github.event.workflow_run.conclusion ==
'success'`, so that deliberate redness stopped the cask update too. The tap sat
at 0.64.22 from 2026-08-03 while v0.64.23, v0.64.24 and v0.64.25 each published
a signed, notarized cmux-macos.dmg.

These assertions pin the two halves of the arrangement: the gate reads the build
job's own conclusion, and the job it names keeps that exact name.
"""

import os
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOMEBREW = os.path.join(ROOT, ".github", "workflows", "update-homebrew.yml")
RELEASE = os.path.join(ROOT, ".github", "workflows", "release.yml")
CI_GUARDS = os.path.join(ROOT, ".github", "workflows", "ci-guards.yml")
BUILD_JOB = "build-sign-notarize"

FAILURES = []


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def main():
    """Check release dependencies and the scoped checksum regression steps."""
    homebrew = yaml.safe_load(open(HOMEBREW, encoding="utf-8"))
    release = yaml.safe_load(open(RELEASE, encoding="utf-8"))
    ci_guards = yaml.safe_load(open(CI_GUARDS, encoding="utf-8"))

    text = open(HOMEBREW, encoding="utf-8").read()
    _check(
        "github.event.workflow_run.conclusion == 'success'" not in text,
        "the cask no longer gates on the whole release run's conclusion",
    )

    jobs = homebrew["jobs"]
    _check("gate" in jobs, "update-homebrew has a gate job")
    gate_run = "".join(
        str(step.get("run", "")) for step in jobs.get("gate", {}).get("steps", [])
    )
    _check(
        f'select(.name == "{BUILD_JOB}")' in gate_run,
        f"the gate reads the {BUILD_JOB} job's conclusion",
    )
    _check(
        '"$conclusion" = "success"' in gate_run,
        "the gate proceeds only when that job concluded success",
    )
    _check(
        homebrew.get("permissions", {}).get("actions") == "read",
        "update-homebrew can read the triggering run's jobs",
    )
    _check(
        jobs.get("update-cask", {}).get("needs") == "gate"
        and "needs.gate.outputs.proceed == 'true'" in str(jobs.get("update-cask", {}).get("if", "")),
        "update-cask runs only when the gate says so",
    )

    # The gate matches on the job's API name, which is the mapping key unless a
    # `name:` overrides it. Renaming one without the other silently stops every
    # future cask update, which is the failure this test exists to prevent.
    release_jobs = release["jobs"]
    _check(BUILD_JOB in release_jobs, f"release.yml still defines {BUILD_JOB}")
    _check(
        "name" not in release_jobs.get(BUILD_JOB, {}),
        f"{BUILD_JOB} has no name: override, so its API name is the key the gate matches",
    )
    # And the decoupling the gate relies on: the DMG must not need screenshots.
    needs = release_jobs.get(BUILD_JOB, {}).get("needs")
    needs = [needs] if isinstance(needs, str) else (needs or [])
    _check(
        "generate-ios-screenshots" not in needs,
        "the signed build does not depend on the iOS screenshot capture",
    )

    guard_steps = ci_guards["jobs"]["workflow-guard-tests"]["steps"]
    submodule_step = next(
        (
            step
            for step in guard_steps
            if "git submodule update --init --depth 1 homebrew-cmux"
            in str(step.get("run", ""))
        ),
        None,
    )
    sha_step = next(
        (
            step
            for step in guard_steps
            if "tests/test_homebrew_sha.sh" in str(step.get("run", ""))
        ),
        None,
    )
    _check(
        submodule_step is not None
        and submodule_step.get("if") == "${{ matrix.group == 'release-notary' }}",
        "release-notary initializes the vendored Homebrew tap before hashing",
    )
    _check(
        sha_step is not None
        and sha_step.get("if") == "${{ matrix.group == 'release-notary' }}"
        and sha_step.get("run") == "HOMEBREW_SHA_TEST_MODE=fixture ./tests/test_homebrew_sha.sh",
        "release-notary runs the deterministic cask digest regression",
    )
    _check(
        submodule_step is not None
        and sha_step is not None
        and guard_steps.index(submodule_step) < guard_steps.index(sha_step),
        "release-notary initializes the vendored Homebrew tap before hashing",
    )
    _check(
        "Cache-Control: no-cache" in text and "homebrew_run=${GITHUB_RUN_ID}" in text,
        "the updater bypasses cached release bytes after an in-place asset repair",
    )
    update_steps = jobs.get("update-cask", {}).get("steps", [])
    update_run = "".join(str(step.get("run", "")) for step in update_steps)
    _check(
        'CASK_SHA=$(grep' in update_run
        and 'ACTUAL_SHA=$(shasum -a 256 cmux.dmg' in update_run
        and 'if [ "$CASK_SHA" != "$ACTUAL_SHA" ]' in update_run,
        "the updater keeps the live cask-versus-release checksum check",
    )

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("\nall release/homebrew gate tests passed")


if __name__ == "__main__":
    main()
