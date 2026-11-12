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
BUILD_JOB = "build-sign-notarize"

FAILURES = []


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def main():
    homebrew = yaml.safe_load(open(HOMEBREW, encoding="utf-8"))
    release = yaml.safe_load(open(RELEASE, encoding="utf-8"))

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

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("\nall release/homebrew gate tests passed")


if __name__ == "__main__":
    main()
