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
import os
import json
import subprocess
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
    # provider branch only on its own runners, and upstream actions stay pinned.
    warp = "inputs.backend == 'warp' && startsWith(runner.name, 'warp-')"
    r2 = "inputs.backend == 'r2'"
    expected_conditions = ["${{ inputs.backend != 'r2' && !(" + warp + ") }}", "${{ " + warp + " }}", "${{ " + r2 + " }}"]
    for kind in ("restore", "save"):
        action = yaml.safe_load((ROOT / ".github/actions" / f"cache-{kind}" / "action.yml").read_text(encoding="utf-8"))
        steps = action["runs"]["steps"]
        if kind == "restore":
            # Measurement is not a fourth cache store. Recognize only these
            # fixed nonblocking commands; all other steps still undergo the
            # exhaustive store-branch checks below.
            measurements = {
                "receipt-clock": (None, 'echo "started_ns=$(python3 -c \'import time; print(time.monotonic_ns())\')" >> "$GITHUB_OUTPUT"'),
                "receipt": ("always()", 'python3 "$GITHUB_ACTION_PATH/../../../scripts/ci/cache_restore_receipt.py"'),
            }
            for identifier, (condition, command) in measurements.items():
                matches = [step for step in steps if step.get("id") == identifier]
                if len(matches) != 1 or any(
                    step.get("if") != condition or step.get("run") != command
                    or step.get("shell") != "bash" or step.get("continue-on-error") is not True
                    or "uses" in step for step in matches
                ):
                    failures.append(f"cache-restore: {identifier} must be the fixed nonblocking measurement step")
            steps = [step for step in steps if step.get("id") not in measurements]
        conditions = [step.get("if") for step in steps]
        if conditions != expected_conditions:
            failures.append(f"cache-{kind}: the store branches must be mutually exclusive and cover every backend, got {conditions}")
        owners = [step["uses"].split("@")[0] for step in steps if "uses" in step]
        if owners != [f"actions/cache/{kind}", f"WarpBuilds/cache/{kind}"]:
            failures.append(f"cache-{kind}: unexpected actions {owners}")
        for step in steps:
            if "uses" not in step:
                if f"scripts/ci/r2-cache.sh\" {kind} " not in step.get("run", ""):
                    failures.append(f"cache-{kind}: the R2 branch must call r2-cache.sh {kind}")
                continue
            revision = step["uses"].split("@")[1]
            if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision):
                failures.append(f"cache-{kind}: {step['uses']} is not pinned to a commit")

    # Bucket credentials reach a save step only when that run saves to R2, and
    # never reach ci.yml, whose jobs run pull request code.
    ci_text = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    if "CF_R2_" in ci_text or "secrets.CI_CACHE_R2_" in ci_text:
        failures.append("ci.yml must not reference the R2 bucket credentials")
    for job_name, step in cache_steps("nightly.yml"):
        for name, value in (step.get("env") or {}).items():
            if "secrets.CF_R2_" in str(value):
                failures.append(f"nightly.yml {job_name}: cache writes must use dedicated CI_CACHE_R2_* credentials, never release credentials")
            if "secrets.CI_CACHE_R2_" in str(value) and "== 'r2' &&" not in str(value):
                failures.append(f"nightly.yml {job_name}: {name} must be empty unless the run saves to R2")

    # Exercise the actual decision script: manual cache seeding must not
    # start app builds or publish, even when other dispatch flags are set.
    nightly = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())
    decision = nightly["jobs"]["decide"]["steps"][0]["with"]["script"]
    harness = """
    const outputs = {};
    const core = {setOutput: (k,v) => outputs[k]=v,
      summary: {addHeading(){return this},addTable(){return this},async write(){}}};
    const context = {repo:{owner:'test',repo:'test'},ref:'refs/heads/main',sha:'test-head'};
    const github = {rest:{git:{getRef:async()=>({data:{object:{type:'commit',sha:'old'}}})}}};
    (async()=>{ SCRIPT; console.log(JSON.stringify(outputs)); })().catch(e=>{console.error(e);process.exit(1)});
    """.replace("SCRIPT", decision)
    result = subprocess.run(["node", "-e", harness], env={**os.environ,
        "SEED_ONLY": "true", "FORCE_BUILD": "true", "BUILD_ONLY": "true", "FAST_BUILD": "true"},
        text=True, capture_output=True, check=True)
    outputs = json.loads(result.stdout)
    if outputs.get("should_build") != "false" or outputs.get("should_publish") != "false":
        failures.append("manual cache-only dispatch must neither build nor publish an app")
    for job in ("refresh-compilation-cache", "refresh-test-compilation-cache"):
        if "inputs.seed_only" not in nightly["jobs"][job]["if"]:
            failures.append(f"{job} must allow manual cache seeding")

    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print("PASS: pull request jobs restore caches read-only, and every Swift package cache they read is seeded from main")
    return 0


if __name__ == "__main__":
    sys.exit(main())
