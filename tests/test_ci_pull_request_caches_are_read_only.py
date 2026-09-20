#!/usr/bin/env python3
"""Pull request jobs read caches and never write them.

A cache saved from a pull request can be read only by that pull request, and
every save pushes the entries seeded from main out of a size-capped store.
ci.yml therefore restores only, and each Swift package cache it restores must
be one a main-branch job in nightly.yml saves under the same key and path. The
local cache-restore and cache-save actions choose the store.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RESTORE = ("actions/cache/restore@", "./.github/actions/cache-restore")
CACHE = ("actions/cache", "./.github/actions/cache-")


def cache_steps(workflow: str) -> list[tuple[str, dict]]:
    document = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text(encoding="utf-8"))
    found = []
    for job_name, job in document["jobs"].items():
        for step in job.get("steps", []):
            if str(step.get("uses", "")).startswith(CACHE):
                found.append((job_name, step))
    return found


def main() -> int:
    failures: list[str] = []

    ci_steps = cache_steps("ci.yml")
    if not ci_steps:
        failures.append("ci.yml has no cache steps; this guard is reading the wrong file")
    for job_name, step in ci_steps:
        if not step["uses"].startswith(RESTORE):
            failures.append(f"ci.yml {job_name}: '{step.get('name')}' uses {step['uses'].split('@')[0]}; pull request jobs must use actions/cache/restore")

    seeded = {
        (step["with"]["key"], step["with"]["path"])
        for _, step in cache_steps("nightly.yml")
        if not step["uses"].startswith(RESTORE)
    }
    for job_name, step in ci_steps:
        key, path = step["with"]["key"], step["with"]["path"]
        if key.startswith("spm-") and (key, path) not in seeded:
            failures.append(f"ci.yml {job_name}: no nightly.yml job saves key '{key}' with path '{path}', so this restore can never hit")

    # The wrappers pick one store per call. Exactly one branch may run, the
    # provider branch only on its own runners, and both actions stay pinned.
    warp = "inputs.backend == 'warp' && startsWith(runner.name, 'warp-')"
    for kind in ("restore", "save"):
        action = yaml.safe_load((ROOT / ".github/actions" / f"cache-{kind}" / "action.yml").read_text(encoding="utf-8"))
        steps = action["runs"]["steps"]
        conditions = [step.get("if") for step in steps]
        if conditions != ["${{ !(" + warp + ") }}", "${{ " + warp + " }}"]:
            failures.append(f"cache-{kind}: the two store branches must be exact complements, got {conditions}")
        owners = [step["uses"].split("@")[0] for step in steps]
        if owners != [f"actions/cache/{kind}", f"WarpBuilds/cache/{kind}"]:
            failures.append(f"cache-{kind}: unexpected actions {owners}")
        for step in steps:
            revision = step["uses"].split("@")[1]
            if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision):
                failures.append(f"cache-{kind}: {step['uses']} is not pinned to a commit")

    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print("PASS: pull request jobs restore caches read-only, and every Swift package cache they read is seeded from main")
    return 0


if __name__ == "__main__":
    sys.exit(main())
