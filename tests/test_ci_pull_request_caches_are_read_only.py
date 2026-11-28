#!/usr/bin/env python3
"""Pull request jobs read caches and never write them.

A cache saved from a pull request can be read only by that pull request, and
every save pushes the entries seeded from main out of a size-capped store.
ci-macos.yml therefore restores only, and each Swift package cache it restores must
be one a main-branch job in nightly.yml saves under the same key and path. The
local cache-restore and cache-save actions choose the store.
"""

from __future__ import annotations

import sys
import json
import os
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402

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


def reads_secret_prefix(value: object, *prefixes: str) -> bool:
    """value reads a secret whose name starts with one of prefixes, in any form GitHub accepts, or every secret
    at once (tests/workflow_jobs.py)."""
    names = workflow_jobs.secret_names(value)
    return workflow_jobs.ALL_SECRETS in names or any(name.startswith(prefixes) for name in names)


def main() -> int:
    failures: list[str] = []

    ci_steps = cache_steps("ci-macos.yml")
    if not ci_steps:
        failures.append("ci-macos.yml has no cache steps; this guard is reading the wrong file")
    for job_name, step in ci_steps:
        if not step["uses"].startswith(RESTORE):
            failures.append(f"ci-macos.yml {job_name}: '{step.get('name')}' uses {step['uses'].split('@')[0]}; pull request jobs must use actions/cache/restore")

    seeded = {
        (step["with"]["key"], step["with"]["path"])
        for _, step in cache_steps("nightly.yml")
        if not step["uses"].startswith(RESTORE)
    }
    for job_name, step in ci_steps:
        key, path = step["with"]["key"], step["with"]["path"]
        if key.startswith("spm-") and (key, path) not in seeded:
            failures.append(f"ci-macos.yml {job_name}: no nightly.yml job saves key '{key}' with path '{path}', so this restore can never hit")

    # canonical-resolve copies the checkout to the canonical root and resolves
    # there, so a workspace `.ci-source-packages` is still exactly what was
    # restored. Only nightly.yml collects the resolved copy before saving;
    # anywhere else a save stores a fallback restore of the previous
    # Package.resolved under the new exact key, and every exact hit then fails
    # its offline resolve (test-e2e.yml, run 36134675453). Every other reader
    # restores the store nightly.yml writes, through cache-restore.
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        if path.name == "nightly.yml":
            continue
        workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
        for job_name, step in cache_steps(path.name):
            key, cache_path = step["with"]["key"], step["with"]["path"]
            if not (key.startswith("spm-") and cache_path == ".ci-source-packages"):
                continue
            if not step["uses"].startswith(RESTORE):
                failures.append(f"{path.name} {job_name}: '{step.get('name')}' saves '{cache_path}' under an `spm-` key; restore only and let nightly.yml seed it")
            elif (key, cache_path) not in seeded:
                failures.append(f"{path.name} {job_name}: no nightly.yml job saves key '{key}' with path '{cache_path}', so this restore can never hit")
            elif not step["uses"].startswith("./.github/actions/cache-restore") or not (step["with"].get("backend") == "r2" or str(step["with"].get("backend", "")).endswith("|| 'r2' }}")):
                failures.append(f"{path.name} {job_name}: '{step.get('name')}' must read the R2 store nightly.yml seeds: ./.github/actions/cache-restore with an r2 backend")
            else:
                # r2-cache.sh treats a missing public URL as a miss, silently.
                # The step's env, then the env the job's steps start from (the workflow's, then the job's).
                scopes = (step.get("env"), workflow_jobs.effective_env(workflow, workflow["jobs"][job_name]))
                if not any("CI_CACHE_R2_PUBLIC_URL" in (scope or {}) for scope in scopes):
                    failures.append(f"{path.name} {job_name}: '{step.get('name')}' has no CI_CACHE_R2_PUBLIC_URL, so its R2 restore always misses")

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

    # Bucket credentials never reach pull-request code in either CI workflow.
    for workflow_name in ("ci.yml", "ci-macos.yml"):
        ci_text = (ROOT / ".github/workflows" / workflow_name).read_text(encoding="utf-8")
        ci_jobs = workflow_jobs.jobs(ci_text)
        if "CF_R2_" in ci_text or reads_secret_prefix(ci_text, "CI_CACHE_R2_") \
                or any(reads_secret_prefix(job, "CI_CACHE_R2_") for job in ci_jobs.values()):
            failures.append(f"{workflow_name} must not reference the R2 bucket credentials")
    for job_name, step in cache_steps("nightly.yml"):
        for name, value in (step.get("env") or {}).items():
            if reads_secret_prefix(value, "CF_R2_"):
                failures.append(f"nightly.yml {job_name}: cache writes must use dedicated CI_CACHE_R2_* credentials, never release credentials")
            if reads_secret_prefix(value, "CI_CACHE_R2_") and "== 'r2' &&" not in str(value):
                failures.append(f"nightly.yml {job_name}: {name} must be empty unless the run saves to R2")

    # The write credentials live in the ci-cache-writer environment, whose
    # deployment branches are limited to main. Every job that names them must
    # enter that environment on main and no environment anywhere else, so a
    # dispatch from another branch still runs and simply saves nothing.
    writer = "${{ github.ref == 'refs/heads/main' && 'ci-cache-writer' || '' }}"
    # A job that also signs cannot enter two environments, so it reads the
    # copies held by the release environment (main and v* tags) and still
    # enters it only on main.
    signing_writer = "${{ github.ref == 'refs/heads/main' && 'release' || '' }}"
    next_writer = "${{ github.ref == 'refs/heads/feat-cmux-next' && 'next-cache-writer' || '' }}"
    next_push_writer = ("${{ github.ref == 'refs/heads/feat-cmux-next' && github.event_name == 'push' "
                        "&& 'next-cache-writer' || '' }}")
    store_signer = ("${{ github.ref == 'refs/heads/main' && 'ci-cache-writer' || "
                    "github.ref == 'refs/heads/nightly-next' && 'artifacts' || '' }}")
    signing_secret = ("IOS_", "ASC_API_", "APPLE_")
    writers = 0
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        for job_name, job in (document.get("jobs") or {}).items():
            if not reads_secret_prefix(job, "CI_CACHE_R2_"):
                continue
            writers += 1
            # A job that calls a reusable workflow cannot enter an environment; it may pass the credentials only on
            # feat-cmux-next, each one by name, and the called workflow's own jobs (checked as they come up in
            # this loop) enter next-cache-writer and write only cmux-ci-cache-next (cmux-tui-artifacts.yml's builds).
            if str(job.get("uses", "")).startswith("./.github/workflows/"):
                passed = job.get("secrets")
                gate = "${{ github.ref == 'refs/heads/feat-cmux-next' && secrets."
                if isinstance(passed, dict) and all(
                        not reads_secret_prefix(value, "CI_CACHE_R2_")
                        or str(value) == f"{gate}{name} || '' }}}}"
                        for name, value in passed.items()) and not reads_secret_prefix(
                            {k: v for k, v in job.items() if k != "secrets"}, "CI_CACHE_R2_"):
                    continue
                failures.append(f"{path.name} {job_name}: a reusable-workflow call passes the R2 write credentials only as"
                                f" {gate}NAME || '' }}}}, each under its own name")
                continue
            environment = workflow_jobs.resolve(job).environment  # a string environment is {"name": it}
            if environment == {"name": writer}:
                continue
            # The nightly-next app build signs cmux's App Store packages with CMUX_STORE_SIGNING_KEY, a
            # secret of the artifacts environment (deployment branches main, feat-cmux-next, nightly-next).
            # It enters ci-cache-writer on main exactly as above and artifacts on nightly-next only, which
            # holds no R2 write credentials, so a nightly-next build still saves nothing.
            if environment == {"name": store_signer} and "CMUX_STORE_SIGNING_KEY" in workflow_jobs.secret_names(job):
                continue
            # Only a named signing secret exempts the job: reading every secret at once is no signing exemption.
            if environment == {"name": signing_writer} and any(
                    name.startswith(signing_secret) for name in workflow_jobs.secret_names(job)):
                continue
            # cmux NEXT writes its own bucket through its own environment, whose
            # deployment branches are feat-cmux-next only; it never names main's
            # bucket (cmux-next-fast-tier-seed.yml).
            # Some jobs further restrict credentials to pushes. Accept that
            # exact form with the same bucket checks, never a partial match.
            if environment in ({"name": next_writer}, {"name": next_push_writer}):
                bucket = workflow_jobs.effective_env(document, job).get("CI_CACHE_R2_BUCKET")
                if bucket == "cmux-ci-cache-next" and "vars.CI_CACHE_R2_BUCKET" not in path.read_text(encoding="utf-8"):
                    continue
                failures.append(f"{path.name} {job_name}: a next-cache-writer job must write only the cmux-ci-cache-next bucket")
                continue
            failures.append(f"{path.name} {job_name}: a job holding the R2 write credentials must declare environment: {writer}")
    if not writers:
        failures.append("no workflow names the R2 write credentials; this guard is reading the wrong tree")

    # Exercise the actual decision script: manual cache seeding must not
    # start app builds or publish, even when other dispatch flags are set.
    nightly = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())
    decision = next(
        step for step in nightly["jobs"]["decide"]["steps"] if step.get("id") == "decide"
    )["with"]["script"]
    harness = """
    const outputs = {};
    const core = {setOutput: (k,v) => outputs[k]=v, notice() {},
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
        # Owned pools serve pull requests, so the scheduled Blacksmith warmers
        # would only burn paid macOS minutes (nightly.yml explains the readers).
        if "vars.CI_PR_POOL_OWNED != '1'" not in nightly["jobs"][job]["if"]:
            failures.append(f"{job} must skip its schedule while owned pools serve pull requests")

    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print("PASS: pull request jobs restore caches read-only, and every Swift package cache they read is seeded from main")
    return 0


if __name__ == "__main__":
    sys.exit(main())
