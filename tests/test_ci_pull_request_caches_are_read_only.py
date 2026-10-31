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
    # seed-derived-data-pool.yml is the one other writer, checked below.
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        if path.name == "nightly.yml":
            continue
        workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
        for job_name, step in cache_steps(path.name):
            key, cache_path = step["with"]["key"], step["with"]["path"]
            if not (key.startswith("spm-") and cache_path == ".ci-source-packages"):
                continue
            if (path.name, job_name, step.get("name")) == ("seed-derived-data-pool.yml", "seed", "Pack Swift packages"):
                continue
            if not step["uses"].startswith(RESTORE):
                failures.append(f"{path.name} {job_name}: '{step.get('name')}' saves '{cache_path}' under an `spm-` key; restore only and let nightly.yml seed it")
            elif (key, cache_path) not in seeded:
                failures.append(f"{path.name} {job_name}: no nightly.yml job saves key '{key}' with path '{cache_path}', so this restore can never hit")
            elif not step["uses"].startswith("./.github/actions/cache-restore") or not (step["with"].get("backend") == "r2" or str(step["with"].get("backend", "")).endswith("|| 'r2' }}")):
                failures.append(f"{path.name} {job_name}: '{step.get('name')}' must read the R2 store nightly.yml seeds: ./.github/actions/cache-restore with an r2 backend")
            else:
                # r2-cache.sh treats a missing public URL as a miss, silently.
                scopes = (step.get("env"), workflow["jobs"][job_name].get("env"), workflow.get("env"))
                if not any("CI_CACHE_R2_PUBLIC_URL" in (scope or {}) for scope in scopes):
                    failures.append(f"{path.name} {job_name}: '{step.get('name')}' has no CI_CACHE_R2_PUBLIC_URL, so its R2 restore always misses")

    # seed-derived-data-pool.yml seeds the package cache from the first main
    # push after a lockfile change. It may save only on main, only on an
    # exact-key miss, only the copy canonical-resolve resolved, and never fail
    # the seed. The build packs it with no credentials and the save job
    # uploads it under the key it computes from the same lockfile.
    pool = yaml.safe_load((ROOT / ".github/workflows/seed-derived-data-pool.yml").read_text(encoding="utf-8"))
    seed_steps, save_steps = pool["jobs"]["seed"]["steps"], pool["jobs"]["save"]["steps"]
    by_name = {step.get("name"): step for step in seed_steps}
    saved_by_name = {step.get("name"): step for step in save_steps}
    names = [step.get("name") for step in seed_steps]
    restore, collect, save, upload = (by_name.get(n) for n in (
        "Cache Swift packages", "Collect resolved Swift packages", "Pack Swift packages", "Upload packed Swift packages"))
    download, publish = (saved_by_name.get(n) for n in ("Download packed Swift packages", "Save Swift packages"))
    if not (restore and collect and save and upload and download and publish):
        failures.append("seed-derived-data-pool.yml: the package cache restore, collect, pack, upload, download and save steps must exist")
    else:
        if save["with"]["key"] != restore["with"]["key"] or save["with"]["path"] != ".ci-source-packages" or (save["with"]["key"], save["with"]["path"]) not in seeded:
            failures.append("seed-derived-data-pool.yml seed: 'Pack Swift packages' must pack nightly.yml's exact `spm-` key and path")
        if not save["uses"].startswith("./.github/actions/cache-save") or save["with"].get("backend") != restore["with"].get("backend") or not save["with"].get("pack-to"):
            failures.append("seed-derived-data-pool.yml seed: 'Pack Swift packages' must pack for the store it restores from")
        if save.get("if") != f"steps.{collect.get('id')}.outcome == 'success'":
            failures.append("seed-derived-data-pool.yml seed: 'Pack Swift packages' must run only after a successful collect")
        condition = str(collect.get("if", ""))
        if f"steps.{restore.get('id')}.outputs.cache-hit != 'true'" not in condition or "github.ref == 'refs/heads/main'" not in condition or restore.get("id") is None:
            failures.append("seed-derived-data-pool.yml seed: collecting packages must require an exact-key miss and the main ref")
        run = collect.get("run", "")
        if '/src/.ci-source-packages"' not in run or 'rsync -a --delete "$resolved/" .ci-source-packages/' not in run or "sanitize-xcode-source-packages-cache.py .ci-source-packages" not in run:
            failures.append("seed-derived-data-pool.yml seed: collect must copy the canonical resolved packages into the workspace and sanitize them")
        if not all(step.get("continue-on-error") is True for step in (collect, save, upload, download, publish)):
            failures.append("seed-derived-data-pool.yml: the package seed must never fail the DerivedData seed")
        if "Resolve Swift packages" not in names or not (names.index("Resolve Swift packages") + 1 == names.index("Collect resolved Swift packages") and names.index("Collect resolved Swift packages") + 1 == names.index("Pack Swift packages") and names.index("Pack Swift packages") + 1 == names.index("Upload packed Swift packages")):
            failures.append("seed-derived-data-pool.yml seed: collect, pack and upload must directly follow resolve, before any step a cancel can cut off")
        # The save job uploads what the build packed, under the key the lockfile names.
        if publish.get("env", {}).get("KEY") != restore["with"]["key"] or 'r2-cache.sh publish "$RUNNER_TEMP/r2-pack/swift-packages" "$KEY"' not in publish.get("run", ""):
            failures.append("seed-derived-data-pool.yml save: 'Save Swift packages' must publish the packed archive under nightly.yml's exact `spm-` key")
        outputs = pool["jobs"]["seed"]["outputs"]
        if (outputs.get("swift-packages-artifact") != f"${{{{ steps.{upload.get('id')}.outputs.artifact-id }}}}"
                or outputs.get("swift-packages-sha256") != f"${{{{ steps.{save.get('id')}.outputs.packed-sha256 }}}}"
                or download["with"].get("artifact-ids") != "${{ needs.seed.outputs.swift-packages-artifact }}"
                or "name" in download["with"]
                or publish.get("if") != f"steps.{download.get('id')}.outcome == 'success'"
                or publish.get("env", {}).get("SHA256") != "${{ needs.seed.outputs.swift-packages-sha256 }}"
                or '"$KEY" "$SHA256"' not in publish.get("run", "")):
            failures.append("seed-derived-data-pool.yml save: 'Save Swift packages' must save exactly the artifact the build uploaded (by id) with the sha256 it packed")

    # The wrappers pick one store per call. Exactly one branch may run, the
    # provider branch only on its own runners, and upstream actions stay pinned.
    warp = "inputs.backend == 'warp' && startsWith(runner.name, 'warp-')"
    r2 = "inputs.backend == 'r2'"
    expected_conditions = ["${{ inputs.backend != 'r2' && !(" + warp + ") }}", "${{ " + warp + " }}", "${{ " + r2 + " }}"]
    # cache-save's R2 branch either uploads, or with `pack-to` only packs for
    # `r2-cache.sh publish` in a job that holds the credentials.
    r2_save = {"${{ " + r2 + " && inputs.pack-to == '' }}": "save", "${{ " + r2 + " && inputs.pack-to != '' }}": "pack"}
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
        expected = expected_conditions if kind == "restore" else expected_conditions[:2] + list(r2_save)
        if conditions != expected:
            failures.append(f"cache-{kind}: the store branches must be mutually exclusive and cover every backend, got {conditions}")
        owners = [step["uses"].split("@")[0] for step in steps if "uses" in step]
        if owners != [f"actions/cache/{kind}", f"WarpBuilds/cache/{kind}"]:
            failures.append(f"cache-{kind}: unexpected actions {owners}")
        for step in steps:
            if "uses" not in step:
                mode = kind if kind == "restore" else r2_save.get(step.get("if"), kind)
                if f"scripts/ci/r2-cache.sh\" {mode} " not in step.get("run", ""):
                    failures.append(f"cache-{kind}: the R2 branch must call r2-cache.sh {mode}")
                continue
            revision = step["uses"].split("@")[1]
            if len(revision) != 40 or any(c not in "0123456789abcdef" for c in revision):
                failures.append(f"cache-{kind}: {step['uses']} is not pinned to a commit")

    # Bucket credentials never reach pull-request code in either CI workflow.
    for workflow_name in ("ci.yml", "ci-macos.yml"):
        ci_text = (ROOT / ".github/workflows" / workflow_name).read_text(encoding="utf-8")
        if "CF_R2_" in ci_text or "secrets.CI_CACHE_R2_" in ci_text:
            failures.append(f"{workflow_name} must not reference the R2 bucket credentials")
    for job_name, step in cache_steps("nightly.yml"):
        for name, value in (step.get("env") or {}).items():
            if "secrets.CF_R2_" in str(value):
                failures.append(f"nightly.yml {job_name}: cache writes must use dedicated CI_CACHE_R2_* credentials, never release credentials")
            if "secrets.CI_CACHE_R2_" in str(value) and "== 'r2' &&" not in str(value):
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
    signing_secret = ("secrets.IOS_", "secrets.ASC_API_", "secrets.APPLE_")
    writers = 0
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        for job_name, job in (document.get("jobs") or {}).items():
            if "secrets.CI_CACHE_R2_" not in json.dumps(job):
                continue
            writers += 1
            if job.get("environment") == writer:
                continue
            # A job that calls a local reusable workflow cannot declare an environment, and
            # GitHub hands a called job an environment secret only when the caller passes it
            # by name. Such a pass is allowed when it is by name (never `inherit`) and every
            # callee job that reads the credentials enters the writer environment (each is
            # checked by this loop too, as its own workflow's job).
            uses = str(job.get("uses", ""))
            if uses.startswith("./.github/workflows/") and isinstance(job.get("secrets"), dict):
                callee = yaml.safe_load((ROOT / uses).read_text(encoding="utf-8"))
                readers = [name for name, called in (callee.get("jobs") or {}).items()
                           if "secrets.CI_CACHE_R2_" in json.dumps(called)]
                if readers and all(callee["jobs"][name].get("environment") == writer for name in readers):
                    continue
            if job.get("environment") == signing_writer and any(name in json.dumps(job) for name in signing_secret):
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
