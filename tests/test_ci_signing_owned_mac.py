#!/usr/bin/env python3
"""A signing job runs on an owned Mac only with the whole Mac to itself and its keychain gone at the end.

Leo, 2026-10-28, on letting the release signing jobs run on our own Macs while
Blacksmith is starved: "ok. idk what the "risk" was before but like.. we can
just read the code and stuff." The order is Linux, then owned Macs, then
Blacksmith macOS last. On an owned Mac a signing job must:

1. reach it only through scripts/ci/signing_runner.py, the picker that offers a
   drained mini (no busy runner) and only while vars.CI_SIGN_OWNED is 1, and
   only on the attempt that ran the pick (`github.run_attempt == 1 && <owned
   pick> && fromJSON(...)`, or `needs.<picker>.outputs.attempt ==
   github.run_attempt && ...` with the picker's `attempt` output its own
   github.run_attempt), so a re-run of failed jobs, which keeps an older pick,
   leaves the fleet; a re-run that picks again may take an owned Mac
   (nightly.yml's legacy sign, 2026-10-30). Every picker output a signing job's runs-on
   reads comes from that script or from nightly_sign_runner.py, which prints
   Blacksmith labels only; any other source fails here;
2. claim the whole Mac before any credential is in reach: its first step is
   CLAIM_GATE, inline and unconditional, before the checkout (which holds the
   job token) and every other step. glaeda's hook gives the job's (workflow,
   job) the exclusive class (glaeda SIGNING_JOBS, the same list as
   SIGNING_JOBS here) and writes GLAEDA_JOB_CLAIM=exclusive and
   GLAEDA_HOOK_SHA256 (its own sha256); the gate fails on an owned Mac without
   the claim or with a hook scripts/ci/glaeda-signing-hooks.txt does not list
   (every listed sha is one glaeda-disk pins, and glaeda's newest pin is
   listed), read at the run's own commit since no checkout has run yet, and
   no workflow names a hook sha itself (NoLiteralHookTests); it sets the job's `claim`
   output to owned when it passes there. A step that runs
   scripts/ci/signing-runner-claim.sh (the same check, and it removes a
   signing keychain a killed job left) comes before every step that names a
   secret, and neither the job's nor the workflow's env names a secret;
3. have a Blacksmith twin, <job>-blacksmith, with the same steps, env,
   outputs and permissions, that signs in the same run when the owned attempt
   never passed its claim gate (glaeda refused the job, or an unlisted hook
   admitted it) or, for a job in FALLBACK_ON_FAILURE, failed after it, and
   that every job reading the signing job's result or
   outputs also needs and reads, so no run fails or goes stale on a refused
   owned Mac;
4. make its keychain with scripts/ci/signing-keychain.sh create (the
   certificate is decoded to a private temporary file that create itself
   removes, and delete removes again) and delete it in an `if: always()` step.

A job that holds a Sparkle private key (SPARKLE_KEY) is a signing job too: the key signs every update a feed
serves, so on a shared mini any other job could read it from the environment. It makes no keychain, so only rule 4
does not apply to it. A signing job whose runs-on has no ephemeral route (owned_only: no blacksmith-* or ubuntu-*
label and no EPHEMERAL_RUNNER_VARIABLES variable, which nightlies never use) runs on an owned Mac however it reaches
it, so rules 1 to 4 apply to it even when it reads no owned pick. nightly.yml's generate-nightly-deltas held the
nightly-next Sparkle key on an owned mini beside other jobs (glaeda's isolated class; run 41180899369 on
cmux14-glaeda-2, 2026-10-31) with no claim gate.

The claim script and the drained-mini pick are tested here too.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.request
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
sys.path.insert(0, str(ROOT / "scripts/ci"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import signing_runner  # noqa: E402
import test_ci_signing_keychain_is_deleted_before_bundle_code as keychain_guard  # noqa: E402

# The jobs glaeda's job-started hook admits as the exclusive class (glaeda scripts/glaeda-cmux-runner-hook
# SIGNING_JOBS). A signing job routed to owned Macs must be one of them, so a new one is added there too.
SIGNING_JOBS = {
    ("nightly.yml", "build-sign-notarize-nightly"), ("nightly.yml", "recover-nightly-next-notarization"),
    ("nightly.yml", "sign-nightly-identity-legacy"), ("nightly.yml", "generate-nightly-deltas"),
    ("nightly.yml", "publish-nightly"), ("nightly.yml", "publish-nightly-next-github"),
    ("nightly.yml", "publish-nightly-next-github-names"),
    ("release.yml", "build-sign-notarize"), ("repair-v0-64-25-helper-rpaths.yml", "repair"),
    ("cmux-next-dev-daily.yml", "sign"),
}
OWNED_PICKER = "scripts/ci/signing_runner.py"
BLACKSMITH_PICKER = "scripts/ci/nightly_sign_runner.py"
CLAIM = "scripts/ci/signing-runner-claim.sh"
CLAIM_GATE_NAME = "Hold the whole Mac before any credential"
CLAIM_GATE_ID = "claim-gate"
# The glaeda hooks whose claim the signing jobs accept: one sha256 per line, then a note.
SIGNING_HOOKS_FILE = ROOT / "scripts/ci/glaeda-signing-hooks.txt"
SIGNING_HOOKS = [line.split()[0] for line in SIGNING_HOOKS_FILE.read_text().splitlines()
                 if line.strip() and not line.startswith("#")]
# glaeda's drain allowlist, every hook sha it ever pinned, oldest first; FIRST_SIGNING_HOOK is the first hook that waits
# out an earlier job's leftover processes (glaeda #1738), so nothing older may be listed.
GLAEDA_DISK_URL = "https://raw.githubusercontent.com/teamleaderleo/glaeda/main/scripts/glaeda-disk"
FIRST_SIGNING_HOOK = "2695209c13db5fe7514daf76d3e8e547b9569ad9a545225e52f7e07dd83d69e4"
# The first step of an owned-routed signing job, word for word: it needs no checkout.
CLAIM_GATE = f"""owned=""
case "${{RUNNER_NAME:-}}" in *-glaeda|*-glaeda-*) owned=1 ;; esac
if [ -d /Users/Shared/cmux-build-fleet ]; then owned=1; fi
if [ -n "$owned" ]; then
  if [ "${{GLAEDA_JOB_CLAIM:-}}" != exclusive ]; then
    echo "::error title=Signing runner::This owned Mac did not give the job the whole mini; this run's Blacksmith job signs instead."
    exit 1
  fi
  hooks=$(curl -fsS --proto '=https' --retry 3 --max-time 20 \\
    "https://raw.githubusercontent.com/${{GITHUB_REPOSITORY}}/${{GITHUB_SHA}}/scripts/ci/glaeda-signing-hooks.txt") || hooks=""
  hook="${{GLAEDA_HOOK_SHA256:-}}"
  listed=""
  if [[ "$hook" =~ ^[0-9a-f]{{64}}$ ]]; then
    while read -r sha _; do if [ "$sha" = "$hook" ]; then listed=1; fi; done <<< "$hooks"
  fi
  if [ -z "$listed" ]; then
    echo "::error title=Signing runner::glaeda hook ${{hook:-unnamed}} is not one scripts/ci/glaeda-signing-hooks.txt lists; this run's Blacksmith job signs instead."
    exit 1
  fi
  echo "claim=owned" >> "$GITHUB_OUTPUT"
fi
"""
TWIN_SUFFIX = "-blacksmith"
# A picker output that is its own attempt number, which a signing job compares with github.run_attempt.
ATTEMPT_OUTPUT = "${{ github.run_attempt }}"
# Signing jobs whose twin also signs when the owned attempt passed its claim and then failed, with the condition that
# says it failed. sign-nightly-identity-legacy runs with continue-on-error, so its result reads success after a failed
# step; signed_ok (true only when every step passed) says, unless the old feed already had the build (skip) or Apple
# already holds its submission (pending: a second signer would submit it again). On
# 2026-10-29 it failed codesign on a mini after its claim (errSecInternalComponent) and, its twin skipped, the run
# published nothing to the old feed. The other twins sign only after a refused claim: release and the v0.64.25 repair
# publish from inside the signing job, so a second signer after a failed one could publish twice.
FALLBACK_ON_FAILURE: dict[tuple[str, str], str] = {}
# Nightly workflows have no Blacksmith twin at all (twin_failures).
NIGHTLY_WORKFLOW = re.compile(r"nightly|notarization")
# The hook from before the leftover-process check (glaeda before #1738): the gate refuses it.
OLD_HOOK = "fb0442d31e23f01326118b7d6be2effd0ba91bff9a0b59c62016c39bc23116da"
NEEDS_OUTPUT = re.compile(r"needs\.([\w-]+)\.outputs\.([\w-]+)")
STEP_OUTPUT = re.compile(r"steps\.([\w-]+)\.outputs\.")
KEYCHAIN_DELETE = re.compile(r"signing-keychain\.sh\s+delete\b")
# needs['a'].outputs['b'] and secrets['X'] are the same references as needs.a.outputs.b and secrets.X; the guard
# reads them in dot form (dotted()), and a reference left with an index that is not a literal (secrets[format(...)],
# needs[x]) fails an owned-routed job, since the guard cannot tell what it reads.
LITERAL_INDEX = re.compile(r"\[\s*'([A-Za-z0-9_-]+)'\s*\]|\[\s*\"([A-Za-z0-9_-]+)\"\s*\]")
DYNAMIC_INDEX = re.compile(r"\b(?:secrets|needs|outputs)\s*\[")
# Status functions that let a step run after an earlier step failed.
# A picker that offers an owned Mac runs its own checked-out code with the routing token, from an environment with no
# branch policy: each of its steps that names a secret runs only on a named ref (github.ref or github.ref_name in its
# if), or only after such a step failed (steps.<that step>.outcome == 'failure').
REF_CONDITION = re.compile(r"\bgithub\.ref(?:_name)?\b")
AFTER_STEP = re.compile(r"^\s*steps\.([\w-]+)\.outcome\s*==\s*'failure'\s*$")
RUNS_AFTER_FAILURE = re.compile(r"\b(?:always|failure|cancelled)\s*\(")
# A Sparkle EdDSA private key (SPARKLE_PRIVATE_KEY, NIGHTLY_SPARKLE_PRIVATE_KEY, SPARKLE_NEXT_PRIVATE_KEY, ...).
SPARKLE_KEY = re.compile(r"secrets\.\w*SPARKLE\w*PRIVATE_KEY", re.IGNORECASE)
# A fork's own runner (`github.repository_owner != 'manaflow-ai' && 'macos-26' ||`): never this repository's.
FORK_ROUTE = re.compile(r"github\.repository_owner\s*!=\s*'manaflow-ai'\s*&&\s*'[^']*'\s*\|\|")
LABEL_LITERAL = re.compile(r"'([^']*)'")


def dotted(value: Any) -> Any:
    """value with every literal index (['x'] or [\"x\"]) in its expressions written as .x."""
    if isinstance(value, str):
        return LITERAL_INDEX.sub(lambda m: "." + (m.group(1) or m.group(2)), value)
    if isinstance(value, dict):
        return {dotted(key): dotted(item) for key, item in value.items()}
    if isinstance(value, list):
        return [dotted(item) for item in value]
    return value


def workflows() -> dict[str, dict]:
    out = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if isinstance(document, dict):
            out[path.name] = document
    return out


def keychain_job(job: dict) -> bool:
    """A job that holds the Developer ID certificate or makes a signing keychain."""
    text = json.dumps(keychain_guard.inline_step_scripts(job))
    return "APPLE_CERTIFICATE_BASE64" in text or bool(keychain_guard.CREATE.search(text)) or any(
        script in text for script in keychain_guard.SCRIPT_MADE_KEYCHAINS.values())


def signing_job(job: dict) -> bool:
    """A keychain job, or a job that holds a Sparkle private key (read in dot form, after dotted())."""
    return keychain_job(job) or bool(SPARKLE_KEY.search(json.dumps(keychain_guard.inline_step_scripts(job))))


def owned_only(runs_on: str) -> bool:
    """runs-on gives this repository no ephemeral runner, so the job runs on an owned Mac: past the fork route, no
    blacksmith-*, ubuntu-* or GitHub-hosted macos-* label and no EPHEMERAL_RUNNER_VARIABLES variable, and an owned
    label or a variable to take one from."""
    text = FORK_ROUTE.sub("", runs_on)
    # The nightly release-pool Linux picker validates RUNNER_POOLS.linux against
    # the three trusted Blacksmith Linux labels before exposing its output. It
    # is an ephemeral route even though it is not one of the scalar signing
    # variables below.
    if "fromJSON(vars.RUNNER_POOLS).linux" in text and "blacksmith-" in text:
        return False
    if any(keychain_guard.EPHEMERAL_LABEL.match(label) or label.startswith("macos-")
           for label in LABEL_LITERAL.findall(text)):
        return False
    if any(re.search(rf"\bvars\.{name}\b", text, re.IGNORECASE)
           for name in keychain_guard.EPHEMERAL_RUNNER_VARIABLES):
        return False
    return "glaeda-" in text or "vars." in text


def picker_ref_failures(name: str, job: dict) -> list[str]:
    """Why picker `name` could hold a secret on any ref; [] when each secret step is held to a named ref."""
    failures, pinned = [], set()
    for index, step in enumerate(job.get("steps") or []):
        if not isinstance(step, dict):
            continue
        condition = str(step.get("if", ""))
        after = AFTER_STEP.match(condition)
        if REF_CONDITION.search(condition) or (after and after.group(1) in pinned):
            pinned.add(str(step.get("id")))
        elif "secrets." in json.dumps(step):
            failures.append(f"picker {name} step {index} names a secret on any ref; its if must name the trusted ref "
                            "(github.ref or github.ref_name)")
    return failures


def picker_scripts(jobs: dict, needed: str, output: str) -> list[str]:
    """The picker scripts behind needs.<needed>.outputs.<output>: the run of every step its value reads."""
    job = jobs.get(needed) or {}
    value = str((job.get("outputs") or {}).get(output, ""))
    steps = {str(step.get("id")): str(step.get("run", "")) for step in job.get("steps") or [] if isinstance(step, dict)}
    found = []
    for step_id in dict.fromkeys(STEP_OUTPUT.findall(value)):
        run = steps.get(step_id, "")
        if OWNED_PICKER in run:  # its `owned` output names a mini; `runner` and `alternate` are nightly_sign_runner's
            owned = re.search(rf"steps\.{re.escape(step_id)}\.outputs\.owned(?:_pool)?\b", value) is not None
            found.append(OWNED_PICKER if owned else BLACKSMITH_PICKER)
        else:
            found.append(BLACKSMITH_PICKER if BLACKSMITH_PICKER in run
                         else f"steps.{step_id} ({run.strip()[:60] or 'no run'})")
    return found or [f"needs.{needed}.outputs.{output} (no step output)"]


def attempt_clauses(jobs: dict, read: str) -> list[str]:
    """The conditions that hold an owned pick `read` (needs.<picker>.outputs.<x>) to the attempt that made it.

    `github.run_attempt == 1`, or the picker's own attempt when its `attempt` output is exactly its run_attempt: a
    re-run of failed jobs keeps the older pick, and the clause is then false, so the job takes Blacksmith."""
    picker = read.split(".")[1]
    clauses = ["github.run_attempt == 1"]
    attempt = str(((jobs.get(picker) or {}).get("outputs") or {}).get("attempt", "")).strip()
    if attempt == ATTEMPT_OUTPUT:
        clauses.append(f"needs.{picker}.outputs.attempt == github.run_attempt")
    return clauses


def twin_failures(jobs: dict, name: str, owned_reads: list[str], workflow: str = "") -> list[str]:
    """Why the owned-routed signing job `name` lacks a same-run Blacksmith twin that every reader of it also reads.

    A twin in FALLBACK_ON_FAILURE also signs after a failed owned attempt, so each reader takes the twin's outputs
    whenever the twin ran, (needs.<twin>.result == 'skipped' && needs.<job>.outputs.X || needs.<twin>.outputs.X): the
    failed attempt's outputs never mix into the twin's."""
    twin_name = name + TWIN_SUFFIX
    if NIGHTLY_WORKFLOW.search(workflow):
        # Nightlies never use Blacksmith (Lawrence, 2026-10-30): no Blacksmith twin; a refused or failed owned
        # attempt is retried by a later nightly run (or the owned-pool rescue's re-run), on owned Macs only.
        return [f"{twin_name}: nightly workflows never take Blacksmith, so no Blacksmith twin"] if twin_name in jobs else []
    failed = FALLBACK_ON_FAILURE.get((workflow, name), "").format(name=name)
    job, twin = jobs[name], jobs.get(twin_name)
    if str((job.get("outputs") or {}).get("claim", "")).strip() != f"${{{{ steps.{CLAIM_GATE_ID}.outputs.claim }}}}":
        return [f"its outputs must carry claim: ${{{{ steps.{CLAIM_GATE_ID}.outputs.claim }}}}, which its twin reads"]
    if not isinstance(twin, dict):
        return [f"no Blacksmith twin {twin_name}, so a refused owned attempt would leave the run unsigned"]
    failures = []
    for key in ("steps", "env", "outputs", "permissions", "environment", "concurrency", "continue-on-error"):
        if twin.get(key) != job.get(key):
            failures.append(f"{twin_name} must have the same {key} as {name} (a YAML alias of it)")
    runs_on = str(twin.get("runs-on", ""))
    if any(read.split(".outputs.")[0] + ".outputs." + read.split(".outputs.")[1] in runs_on for read in owned_reads):
        failures.append(f"{twin_name} runs-on reads the owned pick; it must take Blacksmith only")
    needs = twin.get("needs") or []
    needs = [needs] if isinstance(needs, str) else list(needs)
    own = needs[:-1] if needs and needs[-1] == name else None
    first = job.get("needs") or []
    if own != ([first] if isinstance(first, str) else list(first)):
        failures.append(f"{twin_name} needs must be {name}'s needs, then {name}")
    condition = re.sub(r"\s+", " ", str(twin.get("if", "")))
    runs_on_job = str(job.get("runs-on", ""))
    for read in owned_reads:
        refused = f"needs.{name}.outputs.claim != 'owned'"
        # The twin's attempt clause is the one the signing job's runs-on uses (the first form, if it uses none).
        clauses = attempt_clauses(jobs, read)
        attempt = next((clause for clause in reversed(clauses) if f"{clause} && {read}" in runs_on_job), clauses[0])
        want = (f"!cancelled() && {attempt} && {read} != '' && needs.{name}.result != 'skipped' && "
                f"needs.{name}.result != 'cancelled' && " + (f"({refused} || {failed})" if failed else refused))
        if condition != want:
            failures.append(f"{twin_name} if must be exactly: {want}")
    for other, reader in jobs.items():
        if other in (name, twin_name) or not isinstance(reader, dict):
            continue
        text = json.dumps(reader)
        reader_needs = reader.get("needs") or []
        reader_needs = [reader_needs] if isinstance(reader_needs, str) else list(reader_needs)
        if name not in reader_needs and f"needs.{name}." not in text:
            continue
        if twin_name not in reader_needs:
            failures.append(f"{other} needs {name} but not {twin_name}, so it never sees the twin's sign")
        for ref in re.findall(rf"needs\.{re.escape(name)}\.(outputs\.[\w-]+|result)", text):
            if not ref.startswith("outputs."):
                pair = f"(needs.{twin_name}.result == 'skipped' && needs.{name}.result || needs.{twin_name}.result)"
            elif failed:
                pair = f"(needs.{twin_name}.result == 'skipped' && needs.{name}.{ref} || needs.{twin_name}.{ref})"
            else:
                pair = f"(needs.{twin_name}.{ref} || needs.{name}.{ref})"
            if text.count(f"needs.{name}.{ref}") != text.count(pair):
                failures.append(f"{other} reads needs.{name}.{ref} without the twin first: write it as {pair}")
        condition = str(reader.get("if", ""))
        if not re.search(r"\b(always|cancelled|failure|success)\s*\(", condition):
            failures.append(f"{other} if has no status check, so the twin it needs, skipped, skips it too")
    return failures


def check(documents: dict[str, dict]) -> tuple[list[str], int]:
    failures: list[str] = []
    owned_jobs = 0
    for workflow, document in documents.items():
        document = dotted(document)
        jobs = document.get("jobs") or {}
        for name, job in jobs.items():
            if not isinstance(job, dict) or not signing_job(job):
                continue
            label = f"{workflow} {name}"
            runs_on = str(job.get("runs-on", ""))
            owned_reads = []
            for needed, output in dict.fromkeys(NEEDS_OUTPUT.findall(runs_on)):
                if str(((jobs.get(needed) or {}).get("outputs") or {}).get(output, "")).strip() == ATTEMPT_OUTPUT:
                    continue  # the picker's own attempt number (attempt_clauses()), not a runner label
                scripts = picker_scripts(jobs, needed, output)
                for script in scripts:
                    if script == OWNED_PICKER:
                        owned_reads.append(f"needs.{needed}.outputs.{output}")
                    elif script != BLACKSMITH_PICKER:
                        failures.append(f"{label}: runs-on reads needs.{needed}.outputs.{output}, from {script}; a "
                                        f"signing job's runner comes from {OWNED_PICKER} or {BLACKSMITH_PICKER} only")
            if not owned_reads and DYNAMIC_INDEX.search(runs_on):
                failures.append(f"{label}: runs-on indexes needs or outputs with an expression the guard cannot read")
            # A job with no ephemeral route is on an owned Mac whether or not it reads the owned pick.
            if not owned_reads and not owned_only(runs_on):
                continue
            if DYNAMIC_INDEX.search(json.dumps(job)) or DYNAMIC_INDEX.search(json.dumps(document.get("env") or {})):
                failures.append(f"{label}: indexes secrets, needs or outputs with an expression the guard cannot read")
            owned_jobs += 1
            for needed in dict.fromkeys(read.split(".")[1] for read in owned_reads):
                failures.extend(f"{label}: {why}" for why in picker_ref_failures(needed, jobs.get(needed) or {}))
            if (workflow, name) not in SIGNING_JOBS:
                failures.append(f"{label}: routed to owned Macs but not in SIGNING_JOBS (add it here and to glaeda's "
                                "SIGNING_JOBS, which gives it the whole mini)")
            for read in owned_reads:
                clauses = attempt_clauses(jobs, read)
                if read.endswith(".owned_pool") or read.endswith("_owned_pool"):
                    route_ok = any(re.search(re.escape(clause).replace(r"\ ", r"\s*") + r"\s*&&\s*" +
                                             re.escape(read), runs_on) for clause in clauses)
                    route_shape = f"{' or '.join(clauses)} && {read}"
                else:
                    route_ok = any(re.search(re.escape(clause).replace(r"\ ", r"\s*") + r"\s*&&\s*" + re.escape(read)
                                             + r"\s*&&\s*fromJSON\(\s*" + re.escape(read) + r"\s*\)", runs_on)
                                   for clause in clauses)
                    route_shape = f"{' or '.join(clauses)} && {read} && fromJSON({read})"
                if not route_ok:
                    failures.append(f"{label}: reads {read} other than as `{route_shape}`, so a re-run could stay on the fleet")
            steps = [step for step in keychain_guard.inline_step_scripts(job).get("steps") or []
                     if isinstance(step, dict)]
            publication = workflow == "nightly.yml" and name in {
                "publish-nightly", "publish-nightly-next-github", "publish-nightly-next-github-names"
            }
            gate_index = next((index for index, step in enumerate(steps)
                               if str(step.get("id", "")) == CLAIM_GATE_ID), None)
            gate = steps[gate_index] if gate_index is not None else {}
            gate_ok = (str(gate.get("run", "")).strip() == CLAIM_GATE.strip()
                       and not (set(gate) - {"name", "run", "shell", "id"})
                       and str(gate.get("shell", "bash")) == "bash"
                       and gate.get("id") == CLAIM_GATE_ID)
            if not gate_ok:
                if publication:
                    failures.append(f"{label}: the claim gate ({CLAIM_GATE_NAME}) must copy CLAIM_GATE word for word, "
                                    f"id {CLAIM_GATE_ID}, with no if, uses, env or continue-on-error")
                else:
                    failures.append(f"{label}: the first step must be the claim gate ({CLAIM_GATE_NAME}); CLAIM_GATE "
                                    f"word for word, id {CLAIM_GATE_ID}, with no if, uses, env or continue-on-error")
            elif not publication and gate_index != 0:
                failures.append(f"{label}: the first step must be the claim gate ({CLAIM_GATE_NAME}) before the checkout's token")
            elif publication:
                checkout_index = next((index for index, step in enumerate(steps)
                                       if "actions/checkout@" in str(step.get("uses", ""))), None)
                if checkout_index is None or gate_index <= checkout_index:
                    failures.append(f"{label}: publication claim gate must run after checkout and before release credentials")
            failures.extend(f"{label}: {why}" for why in twin_failures(jobs, name, owned_reads, workflow))
            claim = next((index for index, step in enumerate(steps) if CLAIM in str(step.get("run", ""))), None)
            first_secret = next((index for index, step in enumerate(steps) if "secrets." in json.dumps(step)), None)
            if claim is None:
                failures.append(f"{label}: routed to owned Macs without a step that runs {CLAIM}")
            elif first_secret is not None and first_secret < claim:
                failures.append(f"{label}: step {first_secret} names a secret before the claim step ({claim})")
            else:
                # Its `if` may skip it with the job's own work (cmux-next-dev-daily's sign skips everything without a
                # source artifact); the unconditional first-step gate is what fails the job without the claim.
                if str(steps[claim].get("continue-on-error", "false")) != "false":
                    failures.append(f"{label}: the claim step must fail the job (no continue-on-error)")
                for index, step in enumerate(steps, 0):
                    if "secrets." in json.dumps(step) and RUNS_AFTER_FAILURE.search(str(step.get("if", ""))):
                        failures.append(f"{label}: step {index} names a secret and runs after a failed claim "
                                        f"(if: {step.get('if')})")
            if "secrets." in json.dumps(job.get("env") or {}):
                failures.append(f"{label}: job-level env names a secret, which every step (the claim's too) holds")
            if "secrets." in json.dumps(document.get("env") or {}):
                failures.append(f"{label}: workflow-level env names a secret, which every step (the claim's too) holds")
            text = json.dumps(steps)
            if "security import" in text:
                failures.append(f"{label}: imports a certificate inline; use scripts/ci/signing-keychain.sh create")
            # Rule 4 is the keychain's; a job that only holds a Sparkle key makes none.
            if keychain_job(job) and not any("always()" in str(step.get("if", "")) and KEYCHAIN_DELETE.search(str(step.get("run", "")))
                       for step in steps):
                failures.append(f"{label}: routed to owned Macs without an `if: always()` step that runs "
                                "scripts/ci/signing-keychain.sh delete")
    return failures, owned_jobs


def paired(picker: dict, name: str, job: dict) -> dict:
    """The jobs of a workflow with picker `pick`, the owned-routed signing job `name` and its Blacksmith twin."""
    twin = {**job, "runs-on": "blacksmith-6vcpu-macos-26", "needs": [*job.get("needs", []), name],
            "if": f"!cancelled() && github.run_attempt == 1 && needs.pick.outputs.owned != '' && needs.{name}.result != "
                  f"'skipped' && needs.{name}.result != 'cancelled' && needs.{name}.outputs.claim != 'owned'"}
    return {"pick": picker, name: job, name + TWIN_SUFFIX: twin}


def runner(name: str, labels: list[str], busy: bool = False, status: str = "online") -> dict:
    return {"name": name, "status": status, "busy": busy, "labels": [{"name": label} for label in labels]}


SIDE = "glaeda-side-std-xcode-26.6"
NOW = dt.datetime(2026, 10, 30, 12, 0, tzinfo=dt.timezone.utc)
# warm_distance's job_seconds cell: a 300 s job (p50), 800 s at its p90.
MODEL = {"job_seconds": {"shell-regressions": {"p50": 300, "p90": 800}}}


def started(job: str, seconds_ago: float) -> dict:
    """A pool snapshot `running` entry: the job a runner runs and since when."""
    return {"job": job, "started_at": (NOW - dt.timedelta(seconds=seconds_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")}


class LegacySignReRunTakesAnOwnedMacFirst(unittest.TestCase):
    """A re-run of nightly.yml whose pickers run again routes the legacy sign to an owned Mac first.

    Runs 41077184190 and 41094107023 (2026-10-30): after the owned sign was refused on attempt 1, every later attempt
    (the rescue's re-runs, up to attempt 4) sent sign-nightly-identity-legacy to Blacksmith macOS, which was stalled,
    because its owned route and its twin read the pick on attempt 1 only and the picker was skipped on a re-run that
    built nothing. The old feed got no build from either run."""

    SIGN, PICK = "sign-nightly-identity-legacy", "pick-nightly-sign-runner"

    @classmethod
    def setUpClass(cls) -> None:
        from test_ci_fork_runner_routing import parse_expression
        from test_nightly_trusted_routing import evaluate
        cls.parse, cls.evaluate = staticmethod(parse_expression), staticmethod(evaluate)
        cls.jobs = yaml.safe_load((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))["jobs"]

    def value(self, job: str, field: str, context: dict) -> Any:
        source = str(self.jobs[job][field]).strip().removeprefix("${{").removesuffix("}}").strip()
        source = source.replace("!cancelled() && ", "", 1)
        base = {"github.repository_owner": "manaflow-ai", "github.ref": "refs/heads/nightly-next",
                "needs.legacy-identity-target.outputs.sign_alternate": "blacksmith-12vcpu-macos-26",
                "needs.legacy-identity-target.outputs.sign_runner": "blacksmith-6vcpu-macos-26",
                "vars.CI_NIGHTLY_NEXT_BUILD_RUNNER": "glaeda-nightly-std-xcode-26.6"}
        return self.evaluate(self.parse(source), {**base, **context})

    def test_a_re_run_that_picked_again_takes_the_owned_mac(self) -> None:
        for attempt in (1, 2, 3):
            picked = {"github.run_attempt": attempt, "needs.pick-nightly-sign-runner.outputs.attempt": str(attempt),
                      "needs.pick-nightly-sign-runner.outputs.sign_owned": '["glaeda-runner-m"]'}
            with self.subTest(attempt=attempt):
                self.assertEqual(self.value(self.SIGN, "runs-on", picked), ["glaeda-runner-m"])

    def test_a_re_run_of_failed_jobs_keeps_the_old_pick_off_the_fleet(self) -> None:
        stale = {"github.run_attempt": 2, "needs.pick-nightly-sign-runner.outputs.attempt": "1",
                 "needs.pick-nightly-sign-runner.outputs.sign_owned": '["glaeda-runner-m"]'}
        # Nightlies never use Blacksmith (Lawrence, 2026-10-30): a stale pick falls to the owned nightly slot.
        self.assertEqual(self.value(self.SIGN, "runs-on", stale), "glaeda-nightly-std-xcode-26.6")
        self.assertNotIn(self.SIGN + "-blacksmith", self.jobs, "nightlies never use Blacksmith: no twin")

    def test_the_picker_runs_when_only_the_legacy_sign_does(self) -> None:
        # A full re-run of a published build: no app build, so prepare-nightly-variant is skipped.
        legacy_only = {"needs.prepare-nightly-variant.result": "skipped", "needs.decide.result": "success"}
        self.assertTrue(self.value(self.PICK, "if", legacy_only))
        self.assertFalse(self.value(self.PICK, "if", {**legacy_only, "vars.NIGHTLY_NEXT_LEGACY_IDENTITY": "off"}))
        self.assertFalse(self.value(self.PICK, "if", {**legacy_only, "github.ref": "refs/heads/main"}))
        self.assertTrue(self.value(self.PICK, "if", {"needs.prepare-nightly-variant.result": "success"}))
        outputs = self.jobs[self.PICK]["outputs"]
        self.assertEqual(str(outputs["attempt"]).strip(), "${{ github.run_attempt }}")
        # Any attempt's pick stands (attempt 1 of a push, or once the sweeper's marker is up), as `owned` does.
        self.assertEqual(str(outputs["sign_owned"]).replace("sign-owned", "owned"), str(outputs["owned"]))
        self.assertIn("steps.sign-owned.outputs.owned_pool", str(outputs["sign_owned_pool"]))


class SigningOwnedMacTests(unittest.TestCase):
    def test_owned_pool_label_drops_the_runner_pin(self) -> None:
        self.assertEqual(signing_runner.owned_pool_label('["glaeda-nightly-std-xcode-26.6", "glaeda-runner-cmux12-glaeda-nightly"]'),
                         "glaeda-nightly-std-xcode-26.6")
        self.assertEqual(signing_runner.owned_pool_label(""), "")
        self.assertEqual(signing_runner.owned_pool_label("not-json"), "")

    def test_publication_pool_output_fails_closed_without_controller_evidence(self) -> None:
        runners = [runner("cmux12-glaeda", [SIDE])]
        env = {"ENABLED": "1", "GITHUB_RUN_ATTEMPT": "1", "ROUTE_TOKEN": "t", "SNAPSHOT_TOKEN": "t",
               "GITHUB_REPOSITORY": "manaflow-ai/cmux", "OWNED_LABELS": SIDE}
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            signing_runner.main({**env, "GITHUB_OUTPUT": os.fspath(output)}, ["owned"],
                                lambda token, repo: runners, lambda path: {"jobs": []},
                                lambda token, repo: {}, NOW)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(values["owned_pool"], "")

    def test_workflows(self) -> None:
        failures, owned_jobs = check(workflows())
        self.assertEqual(failures, [])
        self.assertGreaterEqual(owned_jobs, 1, "no signing job reads the owned pick: is this the right tree?")

    def test_the_guard_catches_a_missing_claim_and_cleanup(self) -> None:
        picker = {"outputs": {"owned": "${{ steps.pick.outputs.owned }}"},
                  "steps": [{"id": "pick", "run": f"python3 {OWNED_PICKER} owned"}]}
        good = {"runs-on": "${{ github.run_attempt == 1 && needs.pick.outputs.owned && "
                           "fromJSON(needs.pick.outputs.owned) || 'blacksmith-6vcpu-macos-26' }}",
                "needs": ["pick"], "outputs": {"claim": "${{ steps.claim-gate.outputs.claim }}"},
                "steps": [{"name": CLAIM_GATE_NAME, "id": CLAIM_GATE_ID, "run": CLAIM_GATE}, {"run": CLAIM},
                          {"env": {"APPLE_CERTIFICATE_BASE64": "${{ secrets.APPLE_CERTIFICATE_BASE64 }}"},
                           "run": "scripts/ci/signing-keychain.sh create"},
                          {"if": "always()", "run": "scripts/ci/signing-keychain.sh delete"}]}
        self.assertEqual(check({"release.yml": {"jobs": paired(picker, "build-sign-notarize", good)}}), ([], 1))
        cases = {
            "not in SIGNING_JOBS": ("other.yml", "sign", good),
            "without a step that runs": ("release.yml", "build-sign-notarize",
                                         {**good, "steps": [good["steps"][0], *good["steps"][2:]]}),
            "names a secret before the claim": ("release.yml", "build-sign-notarize",
                                                {**good, "steps": [good["steps"][0], good["steps"][2], good["steps"][1],
                                                                   good["steps"][3]]}),
            "without an `if: always()` step": ("release.yml", "build-sign-notarize",
                                               {**good, "steps": good["steps"][:3]}),
            "must fail the job": ("release.yml", "build-sign-notarize",
                                         {**good, "steps": [good["steps"][0], {"run": CLAIM, "continue-on-error": True},
                                                            *good["steps"][2:]]}),
            "runs after a failed claim": ("release.yml", "build-sign-notarize",
                                          {**good, "steps": [*good["steps"][:2], {**good["steps"][2], "if": "always()"},
                                                             good["steps"][3]]}),
            "the first step must be the claim gate": ("release.yml", "build-sign-notarize",
                                                      {**good, "steps": [{"uses": "actions/checkout@v6"},
                                                                         *good["steps"]]}),
            "the first step must be the claim gate (Hold": ("release.yml", "build-sign-notarize",
                                      {**good, "steps": [{**good["steps"][0], "if": "success()"}, *good["steps"][1:]]}),
            "a re-run could stay": ("release.yml", "build-sign-notarize",
                                    {**good, "runs-on": "${{ needs.pick.outputs.owned || 'blacksmith-6vcpu-macos-26' }}"}),
        }
        for needle, (workflow, name, job) in cases.items():
            with self.subTest(needle):
                failures, _ = check({workflow: {"jobs": paired(picker, name, job)}})
                self.assertTrue(any(needle in failure for failure in failures), failures)
        twin_name = "build-sign-notarize" + TWIN_SUFFIX
        both = paired(picker, "build-sign-notarize", good)
        reader = {"needs": ["build-sign-notarize", twin_name],
                  "if": "!cancelled() && (needs.build-sign-notarize-blacksmith.outputs.claim || "
                        "needs.build-sign-notarize.outputs.claim) != ''"}
        self.assertEqual(check({"release.yml": {"jobs": {**both, "publish": reader}}}), ([], 1))
        twin_cases = {
            "no Blacksmith twin": {k: v for k, v in both.items() if k != twin_name},
            "must carry claim": {**both, "build-sign-notarize": {**good, "outputs": {}}},
            "must have the same steps": {**both, twin_name: {**both[twin_name], "steps": good["steps"][1:]}},
            "must take Blacksmith only": {**both, twin_name: {**both[twin_name], "runs-on": good["runs-on"]}},
            "if must be exactly": {**both, twin_name: {**both[twin_name], "if": "always()"}},
            "needs must be": {**both, twin_name: {**both[twin_name], "needs": ["pick"]}},
            "but not build-sign-notarize-blacksmith": {**both, "publish": {**reader, "needs": ["build-sign-notarize"]}},
            "without the twin first": {**both, "publish": {**reader, "if": "!cancelled() && "
                                                           "needs.build-sign-notarize.outputs.claim != ''"}},
            "has no status check": {**both, "publish": {**reader, "if": "(needs.build-sign-notarize-blacksmith.outputs."
                                                        "claim || needs.build-sign-notarize.outputs.claim) != ''"}},
        }
        for needle, jobs in twin_cases.items():
            with self.subTest(needle):
                failures, _ = check({"release.yml": {"jobs": jobs}})
                self.assertTrue(any(needle in failure for failure in failures), failures)
        failures, _ = check({"release.yml": {"env": {"K": "${{ secrets.K }}"},
                                             "jobs": paired(picker, "build-sign-notarize", good)}})
        self.assertTrue(any("workflow-level env names a secret" in failure for failure in failures), failures)
        brackets = {**good, "runs-on": "${{ github.run_attempt == 1 && needs['pick'].outputs['owned'] && "
                                       "fromJSON(needs[\"pick\"].outputs.owned) || 'blacksmith-6vcpu-macos-26' }}",
                    "steps": [good["steps"][0], {"env": {"K": "${{ secrets['APPLE_CERTIFICATE_BASE64'] }}"},
                                                 "run": "true"}, *good["steps"][1:]]}
        failures, owned = check({"release.yml": {"jobs": paired(picker, "build-sign-notarize", brackets)}})
        self.assertEqual(owned, 1, "bracket notation still reads as the owned pick")
        self.assertTrue(any("names a secret before the claim" in failure for failure in failures), failures)
        dynamic = {**good, "steps": [*good["steps"][:2], {"env": {"K": "${{ secrets[format('A{0}', 'X')] }}"},
                                                           "run": "true"}, *good["steps"][2:]]}
        failures, _ = check({"release.yml": {"jobs": paired(picker, "build-sign-notarize", dynamic)}})
        self.assertTrue(any("cannot read" in failure for failure in failures), failures)
        failures, _ = check({"release.yml": {"jobs": paired(picker, "build-sign-notarize", {
            **good, "runs-on": "${{ fromJSON(needs[format('pi{0}', 'ck')].outputs.owned) }}"})}})
        self.assertTrue(any("cannot read" in failure for failure in failures), failures)
        open_picker = {**picker, "steps": [{"id": "mint", "if": "vars.X == '1'", "with": {"k": "${{ secrets.K }}"}},
                                           *picker["steps"]]}
        failures, _ = check({"release.yml": {"jobs": paired(open_picker, "build-sign-notarize", good)}})
        self.assertTrue(any("names a secret on any ref" in failure for failure in failures), failures)
        pinned = {**picker, "steps": [{"id": "mint", "if": "vars.X == '1' && github.ref == 'refs/heads/main'",
                                       "with": {"k": "${{ secrets.K }}"}},
                                      {"id": "again", "if": "steps.mint.outcome == 'failure'",
                                       "with": {"k": "${{ secrets.K }}"}}, *picker["steps"]]}
        self.assertEqual(check({"release.yml": {"jobs": paired(pinned, "build-sign-notarize", good)}}), ([], 1))
        other = {"outputs": {"owned": "${{ steps.pick.outputs.owned }}"},
                 "steps": [{"id": "pick", "run": "python3 scripts/ci/nightly_build_runner.py verify"}]}
        failures, _ = check({"release.yml": {"jobs": paired(other, "build-sign-notarize", good)}})
        self.assertTrue(any("signing job's runner comes from" in failure for failure in failures), failures)

    def test_an_owned_only_job_with_a_sparkle_key_holds_the_whole_mac(self) -> None:
        """nightly.yml's generate-nightly-deltas (2026-10-31): the Sparkle key on an owned mini with no claim."""
        key = {"env": {"NEXT_SPARKLE_PRIVATE_KEY": "${{ secrets.SPARKLE_NEXT_PRIVATE_KEY }}"},
               "run": "./scripts/ci/generate-nightly-deltas.sh"}
        owned = "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_SIDE_LANE_RUNNER || " \
                "'glaeda-std-xcode-26.6' }}"
        bare = {"runs-on": owned, "steps": [{"uses": "actions/checkout@v6"}, key]}
        # A job SIGNING_JOBS does not name, so every finding shows.
        failures, owned_jobs = check({"other-nightly.yml": {"jobs": {"deltas": bare}}})
        self.assertEqual(owned_jobs, 1, failures)
        for needle in ("not in SIGNING_JOBS", "the first step must be the claim gate", "without a step that runs"):
            with self.subTest(needle):
                self.assertTrue(any(needle in failure for failure in failures), failures)
        in_job_env = {"runs-on": owned, "env": key["env"], "steps": [{"run": "true"}]}
        failures, _ = check({"other-nightly.yml": {"jobs": {"deltas": in_job_env}}})
        self.assertTrue(any("job-level env names a secret" in failure for failure in failures), failures)
        # Held whole: the claim gate first, the claim before the key, and no keychain to delete (rule 4 is the keychain's).
        held = {"runs-on": owned, "steps": [{"name": CLAIM_GATE_NAME, "id": CLAIM_GATE_ID, "run": CLAIM_GATE},
                                            {"uses": "actions/checkout@v6"}, {"run": CLAIM}, key]}
        self.assertEqual(check({"nightly.yml": {"jobs": {"sign-nightly-identity-legacy": held}}}), ([], 1))
        # A Sparkle job with an ephemeral route is rule 7's (test_ci_signing_keychain_is_deleted_before_bundle_code).
        for runs_on in ("${{ vars.LINUX_RUNNER || 'blacksmith-2vcpu-ubuntu-2404' }}", "blacksmith-6vcpu-macos-26",
                        "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.MACOS_RUNNER_26 }}"):
            with self.subTest(runs_on=runs_on):
                self.assertEqual(check({"nightly.yml": {"jobs": {"publish": {**bare, "runs-on": runs_on}}}}), ([], 0))

    def test_drained_runner_takes_only_a_mini_running_nothing(self) -> None:
        runners = [
            runner("cmux12-glaeda", [SIDE, "glaeda-runner-cmux12-glaeda"]),
            runner("cmux12-glaeda-2", ["glaeda-gui-std-xcode-26.6"], busy=True),  # a busy gui runner: not drained
            runner("cmux13-glaeda-3", [SIDE, "glaeda-runner-cmux13-glaeda-3"]),
            runner("cmux13-glaeda-nightly-next", ["glaeda-trusted-next-nightly"]),
            runner("cmux14-glaeda", [SIDE]),  # no runner label of its own: cannot be pinned
            runner("cmux15-glaeda", [SIDE, "glaeda-runner-cmux15-glaeda"], status="offline"),
        ]
        labels, why = signing_runner.drained_runner(runners, [SIDE])
        self.assertEqual(json.loads(labels), [SIDE, "glaeda-runner-cmux13-glaeda-3"], why)
        # glaeda parks most of a mini's runners offline; an offline runner GitHub calls idle runs nothing.
        runners.append(runner("cmux13-glaeda-5", ["glaeda-gui-std-xcode-26.6"], status="offline"))
        labels, why = signing_runner.drained_runner(runners, [SIDE])
        self.assertEqual(json.loads(labels), [SIDE, "glaeda-runner-cmux13-glaeda-3"],
                         f"a parked offline slot must not keep its mini: {why}")
        runners[-1]["busy"] = True
        self.assertEqual(signing_runner.drained_runner(runners, [SIDE])[0], "",
                         "an offline runner GitHub still calls busy may run a job: its mini is not offered")
        runners.pop()
        runners[3]["busy"] = True  # the mini's dedicated builder is building: that mini is not drained either
        self.assertEqual(signing_runner.drained_runner(runners, [SIDE]), (
            "", f"no mini with an idle `{SIDE}` runner is drained now"))
        self.assertEqual(signing_runner.drained_runner(runners, ["blacksmith-6vcpu-macos-26"])[0], "")
        slot = "glaeda-nightly-std-xcode-26.6"  # glaeda's nightly slot, which CI_NIGHTLY_NEXT_BUILD_RUNNER may name
        labels, why = signing_runner.drained_runner(
            [runner("cmux20-glaeda-nightly", [slot, "glaeda-runner-cmux20-glaeda-nightly"])], [slot])
        self.assertEqual(json.loads(labels), [slot, "glaeda-runner-cmux20-glaeda-nightly"], why)
        self.assertEqual(signing_runner.member("cmux13-glaeda-nightly-next"), "cmux13")

    def test_with_no_drained_mini_a_nightly_slot_is_offered_to_drain(self) -> None:
        """Under steady PR load no mini is ever drained (run 40859232446: "no mini with an idle ... runner is drained
        now"), so legacy signing always went to Blacksmith. Then an idle nightly slot on the mini whose busy runners
        finish soonest is offered (DRAIN_BY_REMAINING_TIME): glaeda holds every new job off that mini while the signing
        job waits there (SIGNING_DRAIN). A side label alone (the DEV daily's) is never drained for."""
        slot = "glaeda-nightly-std-xcode-26.6"
        runners = [
            runner("cmux12-glaeda", [SIDE], busy=True),
            runner("cmux12-glaeda-2", [SIDE], busy=True),
            runner("cmux12-glaeda-nightly", [slot, "glaeda-runner-cmux12-glaeda-nightly"]),
            runner("cmux13-glaeda", [SIDE], busy=True),
            runner("cmux13-glaeda-3", [SIDE, "glaeda-runner-cmux13-glaeda-3"]),  # idle side runner, busy mini
            runner("cmux13-glaeda-nightly", [slot, "glaeda-runner-cmux13-glaeda-nightly"]),
            runner("cmux14-glaeda-nightly", [slot, "glaeda-runner-cmux14-glaeda-nightly"], busy=True),
            runner("cmux14-glaeda", [SIDE]),
            runner("cmux15-glaeda", [SIDE], busy=True),
            runner("cmux15-glaeda-nightly", [slot, "glaeda-runner-cmux15-glaeda-nightly"], status="offline"),
        ]
        # remaining_seconds is at least 60 s, so cmux13's one runner (50 s, read as 60) ends before cmux12's two.
        running = {"cmux12-glaeda": started("macOS / Shell regressions (1)", 200),  # 100 s left
                   "cmux12-glaeda-2": started("macOS / Shell regressions (2)", 210),  # 90 s left
                   "cmux13-glaeda": started("macOS / Shell regressions (3)", 250)}  # 50 s left
        labels, why = signing_runner.drained_runner(runners, [slot, SIDE], running=running, model=MODEL, now=NOW)
        self.assertEqual(json.loads(labels), [slot, "glaeda-runner-cmux13-glaeda-nightly"],
                         f"the mini whose busy runners finish first, and only through the nightly slot: {why}")
        self.assertIn("to drain", why)
        self.assertIn("1 busy runner(s)", why)
        self.assertEqual(signing_runner.drained_runner(runners, [SIDE], running=running, model=MODEL, now=NOW), (
            "", f"no mini with an idle `{SIDE}` runner is drained now"), "the DEV daily's side label never drains")
        running["cmux13-glaeda"] = started("macOS / Shell regressions (3)", 190)  # 110 s left: cmux12 is sooner
        labels, why = signing_runner.drained_runner(runners, [slot, SIDE], running=running, model=MODEL, now=NOW)
        self.assertEqual(json.loads(labels), [slot, "glaeda-runner-cmux12-glaeda-nightly"],
                         f"two busy runners that end sooner beat one that ends later: {why}")
        self.assertIn("2 busy runner(s)", why)
        runners[3]["busy"] = runners[4]["busy"] = True
        runners[0]["busy"] = runners[1]["busy"] = False
        labels, why = signing_runner.drained_runner(runners, [slot, SIDE], running=running, model=MODEL, now=NOW)
        self.assertEqual(json.loads(labels), [slot, "glaeda-runner-cmux12-glaeda-nightly"], why)
        self.assertNotIn("to drain", why, "a drained mini still comes first")
        tie = [runner("cmux21-glaeda", [SIDE], busy=True),
               runner("cmux21-glaeda-nightly", [slot, "glaeda-runner-cmux21-glaeda-nightly"]),
               runner("cmux20-glaeda", [SIDE], busy=True),
               runner("cmux20-glaeda-nightly", [slot, "glaeda-runner-cmux20-glaeda-nightly"])]
        both = {"cmux21-glaeda": started("macOS / Shell regressions", 250),
                "cmux20-glaeda": started("macOS / Shell regressions", 250)}
        self.assertEqual(json.loads(signing_runner.drained_runner(tie, [slot], running=both, model=MODEL,
                                                                  now=NOW)[0])[1],
                         "glaeda-runner-cmux20-glaeda-nightly", "a tie goes by name, so two pickers agree")
        self.assertEqual(signing_runner.member("blacksmith-runner"), "")

    def test_a_busy_runner_whose_remaining_time_is_unknown_keeps_its_mini_busy(self) -> None:
        """DRAIN_BY_REMAINING_TIME: the 2026-10-30 refusals. cmux12s had one busy runner (swift-test, which the model
        has no length for) and the fewest-busy pick drained it for 600 s eleven times. A busy runner with no estimate
        (no snapshot entry, an unmodelled job, one past its p90, no fresh snapshot) never lets its mini be drained."""
        slot = "glaeda-nightly-std-xcode-26.6"
        runners = [runner("cmux12-glaeda-2", [SIDE], busy=True),
                   runner("cmux12-glaeda-nightly", [slot, "glaeda-runner-cmux12-glaeda-nightly"]),
                   runner("cmux13-glaeda", [SIDE], busy=True),
                   runner("cmux13-glaeda-2", [SIDE], busy=True),
                   runner("cmux13-glaeda-nightly", [slot, "glaeda-runner-cmux13-glaeda-nightly"])]
        modelled = {"cmux13-glaeda": started("macOS / Shell regressions (1)", 260),
                    "cmux13-glaeda-2": started("macOS / Shell regressions (2)", 270)}
        for case, entry in (("an unmodelled job", started("macOS / swift-test", 30)),
                            ("no snapshot entry", None),
                            ("a job past its p90", started("macOS / Shell regressions", 900))):
            running = dict(modelled, **({"cmux12-glaeda-2": entry} if entry else {}))
            labels, why = signing_runner.drained_runner(runners, [slot, SIDE], running=running, model=MODEL, now=NOW)
            self.assertEqual(json.loads(labels), [slot, "glaeda-runner-cmux13-glaeda-nightly"],
                             f"{case}: the mini with one busy runner of unknown length is not the one drained: {why}")
        labels, why = signing_runner.drained_runner(runners, [slot, SIDE], running=None, model=MODEL, now=NOW)
        self.assertEqual(labels, "", why)
        self.assertIn("2 of 2 with a busy runner whose remaining time is unknown (no fresh pool snapshot)", why)
        self.assertIn("signs on Blacksmith now", why)

    def test_no_mini_that_frees_up_within_the_horizon_means_blacksmith_now(self) -> None:
        """DRAIN_BY_REMAINING_TIME: a mini is offered only when every busy runner on it finishes within
        DRAIN_HORIZON_SECONDS (2 min); past that the job signs on Blacksmith at once instead of waiting out glaeda's
        600 s drain and being refused."""
        slot = "glaeda-nightly-std-xcode-26.6"
        self.assertEqual(signing_runner.DRAIN_HORIZON_SECONDS, 120.0)
        runners = [runner("cmux12-glaeda", [SIDE], busy=True),
                   runner("cmux12-glaeda-nightly", [slot, "glaeda-runner-cmux12-glaeda-nightly"])]
        for ran, offered in ((180, True), (179, False), (0, False)):  # 120 s, 121 s and 300 s left
            labels, why = signing_runner.drained_runner(
                runners, [slot], running={"cmux12-glaeda": started("macOS / Shell regressions", ran)}, model=MODEL,
                now=NOW)
            if offered:
                self.assertEqual(json.loads(labels), [slot, "glaeda-runner-cmux12-glaeda-nightly"], why)
                self.assertIn("about 120 s", why)
            else:
                self.assertEqual(labels, "", f"{300 - ran} s left is past the horizon: {why}")
                self.assertIn("frees up within 120 s (0 of 1 with a busy runner whose remaining time is unknown)", why)

    def test_drain_anyway_drains_the_soonest_mini_instead_of_blacksmith(self) -> None:
        """DRAIN_ANYWAY (nightly.yml's legacy sign, Leo 2026-10-30): past the horizon, or with no estimate, the nightly
        slot on the mini that frees up soonest is still offered; known waits come before unknown ones, then the fewest
        busy runners. Without it the horizon still sends the job to Blacksmith."""
        slot = "glaeda-nightly-std-xcode-26.6"
        runners = [runner("cmux12-glaeda", [SIDE], busy=True),
                   runner("cmux12-glaeda-2", [SIDE], busy=True),
                   runner("cmux12-glaeda-nightly", [slot, "glaeda-runner-cmux12-glaeda-nightly"]),
                   runner("cmux13-glaeda", [SIDE], busy=True),
                   runner("cmux13-glaeda-nightly", [slot, "glaeda-runner-cmux13-glaeda-nightly"])]
        self.assertEqual(signing_runner.drained_runner(runners, [slot], running=None, model=MODEL, now=NOW)[0], "")
        labels, why = signing_runner.drained_runner(runners, [slot], running=None, model=MODEL, now=NOW,
                                                    drain_anyway=True)
        self.assertEqual(json.loads(labels), [slot, "glaeda-runner-cmux13-glaeda-nightly"],
                         f"no estimate anywhere: the mini with the fewest busy runners: {why}")
        self.assertIn("to drain anyway", why)
        self.assertIn("remaining time unknown", why)
        running = {"cmux12-glaeda": started("macOS / Shell regressions (1)", 0),  # 300 s left
                   "cmux12-glaeda-2": started("macOS / Shell regressions (2)", 0)}  # 300 s left
        labels, why = signing_runner.drained_runner(runners, [slot], running=running, model=MODEL, now=NOW,
                                                    drain_anyway=True)
        self.assertEqual(json.loads(labels), [slot, "glaeda-runner-cmux12-glaeda-nightly"],
                         f"a known wait past the horizon beats an unknown one: {why}")
        self.assertIn("about 300 s", why)
        self.assertEqual(signing_runner.drained_runner(runners, [SIDE], running=None, model=MODEL, now=NOW,
                                                       drain_anyway=True)[0], "",
                         "a side label alone is still never drained for")
        env = {"ENABLED": "1", "GITHUB_RUN_ATTEMPT": "1", "ROUTE_TOKEN": "t", "SNAPSHOT_TOKEN": "t",
               "GITHUB_REPOSITORY": "o/r", "OWNED_LABELS": slot, "DRAIN_ANYWAY": "1"}
        labels, why = signing_runner.owned_pick(env, lambda token, repo: runners, lambda url: {"jobs": []},
                                                lambda token, repo: {}, now=NOW, sleep=lambda seconds: None)
        self.assertEqual(json.loads(labels), [slot, "glaeda-runner-cmux13-glaeda-nightly"], why)
        jobs = workflows()["nightly.yml"]["jobs"]
        step = next(s for s in jobs["pick-nightly-sign-runner"]["steps"] if s.get("id") == "sign-owned")
        self.assertEqual(step["env"].get("DRAIN_ANYWAY"), "1", "the legacy sign drains a mini before Blacksmith")

    def test_owned_pick_drains_only_from_a_fresh_pool_snapshot(self) -> None:
        """owned_pick reads `running` from the queue janitor's pool snapshot (no new GitHub polling) and passes it on
        only when it is at most DRAIN_SNAPSHOT_MAX_MINUTES old; an older or unreadable one leaves every busy runner
        unknown, so nothing is drained."""
        slot = "glaeda-nightly-std-xcode-26.6"
        runners = [runner("cmux12-glaeda", [SIDE], busy=True),
                   runner("cmux12-glaeda-nightly", [slot, "glaeda-runner-cmux12-glaeda-nightly"])]
        env = {"ENABLED": "1", "GITHUB_RUN_ATTEMPT": "1", "ROUTE_TOKEN": "t", "SNAPSHOT_TOKEN": "t",
               "GITHUB_REPOSITORY": "o/r",
               "OWNED_LABELS": f"{slot} {SIDE}"}

        def snap(age_minutes: float) -> dict:
            return {"generated_at": (NOW - dt.timedelta(minutes=age_minutes)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "pools": {}, "running": {"cmux12-glaeda": started("macOS / Shell regressions", 250)}}

        def pick(read_snapshot: Any) -> tuple[str, str]:
            return signing_runner.owned_pick(env, lambda token, repo: runners, lambda url: {"jobs": []},
                                             read_snapshot, now=NOW, sleep=lambda seconds: None)

        model = signing_runner.warm_distance.load_model
        signing_runner.warm_distance.load_model = lambda *a, **k: MODEL
        try:
            labels, why = pick(lambda token, repo: snap(5))
            self.assertEqual(json.loads(labels), [slot, "glaeda-runner-cmux12-glaeda-nightly"], why)
            for stale in (lambda token, repo: snap(16), lambda token, repo: {}):
                labels, why = pick(stale)
                self.assertEqual(labels, "", why)
                self.assertIn("no fresh pool snapshot", why)
        finally:
            signing_runner.warm_distance.load_model = model

    def test_owned_pick_is_off_unless_enabled_on_attempt_one_with_a_token(self) -> None:
        runners = [runner("cmux12-glaeda", [SIDE, "glaeda-runner-cmux12-glaeda"])]
        env = {"ENABLED": "1", "ROUTE_TOKEN": "t", "GITHUB_REPOSITORY": "manaflow-ai/cmux", "OWNED_LABELS": SIDE,
               "GITHUB_RUN_ATTEMPT": "1"}
        read = lambda token, repo: runners  # noqa: E731
        held: list[dict] = []  # signing jobs now running on an owned Mac, as the jobs API lists them

        run_status = ["in_progress"]

        def jobs(path: str) -> dict:
            if not path.endswith("&page=1"):
                return {}  # every listing here fits one page
            if "/runs?" in path:
                return {"workflow_runs": [{"id": 7}] if "nightly.yml" in path and f"status={run_status[0]}&" in path
                        else []}
            return {"jobs": held}

        self.assertTrue(signing_runner.owned_pick(env, read, jobs)[0])
        for change in ({"ENABLED": ""}, {"ENABLED": "0"}, {"GITHUB_RUN_ATTEMPT": "2"}, {"ROUTE_TOKEN": ""}):
            with self.subTest(change):
                self.assertEqual(signing_runner.owned_pick({**env, **change}, read, jobs)[0], "")
        # A workflow that picks again on a re-run and reads it only there (nightly.yml's legacy sign) opts in.
        self.assertTrue(signing_runner.owned_pick({**env, "GITHUB_RUN_ATTEMPT": "3", "PICK_ON_RERUN": "1"}, read,
                                                  jobs)[0])
        self.assertEqual(signing_runner.owned_pick({**env, "GITHUB_RUN_ATTEMPT": "3", "PICK_ON_RERUN": "0"}, read,
                                                   jobs)[0], "")
        self.assertEqual(signing_runner.owned_pick(env, read)[0], "", "no actions: read token: no owned Mac")

        def broken(token: str, repo: str) -> list:
            raise RuntimeError("403")

        self.assertEqual(signing_runner.owned_pick(env, broken, jobs)[0], "")

        def unreadable(path: str) -> dict:
            raise RuntimeError("403")

        self.assertEqual(signing_runner.owned_pick(env, read, unreadable)[0], "", "an uncounted cap fails closed")
        # At most one mini is held for signing: a signing job already pinned to an owned runner leaves none.
        held.append({"name": "sign-nightly-identity-legacy", "status": "in_progress",
                     "labels": [SIDE, "glaeda-runner-cmux13-glaeda-3"]})
        owned, why = signing_runner.owned_pick(env, read, jobs)
        self.assertEqual(owned, "", why)
        self.assertIn("already hold an owned Mac", why)
        held[0]["labels"] = [SIDE]  # publication controls use the shared pool label, without a runner pin
        owned, why = signing_runner.owned_pick(env, read, jobs)
        self.assertEqual(owned, "", why)
        self.assertIn("already hold an owned Mac", why)
        held[0]["labels"] = [SIDE, "glaeda-runner-cmux13-glaeda-3"]
        for status in ("waiting", "pending", "requested"):  # every unfinished run status a started run can have
            with self.subTest(run_status=status):
                run_status[0] = status
                self.assertEqual(signing_runner.owned_pick(env, read, jobs)[0], "")
        run_status[0] = "queued"  # no job of a queued run has started, so none carries a pin: never read
        self.assertTrue(signing_runner.owned_pick(env, read, jobs)[0])
        reads: list[str] = []
        signing_runner.owned_signing_jobs(lambda path: reads.append(path) or {})
        self.assertFalse([path for path in reads if "status=queued" in path],
                         "over 100 queued runs failed every pick closed (runs 40897459413, 40905688542)")
        run_status[0] = "in_progress"
        fails = [502]

        def flaky(path: str) -> dict:
            if fails:
                import urllib.error  # noqa: PLC0415
                raise urllib.error.HTTPError(path, fails.pop(), "Bad Gateway", {}, None)
            return jobs(path)

        kept = list(held)
        held.clear()
        self.assertTrue(signing_runner.owned_pick(env, read, flaky)[0], "one 502 is retried, and the count goes on")
        self.assertEqual(fails, [])
        fails[:] = [404]
        self.assertEqual(signing_runner.owned_pick(env, read, flaky)[0], "", "a 4xx is not retried: fails closed")
        fails[:] = [502, 502, 502]
        self.assertEqual(signing_runner.owned_pick(env, read, flaky)[0], "", "persistent 5xx fails closed")
        held[:] = kept

        def lagging(path: str) -> dict:  # total_count ahead of what is listed: the pages are what counts
            if not path.endswith("&page=1"):
                return {}
            if "/runs?" in path:
                return {"total_count": 101, "workflow_runs": [{"id": 7}]}
            return {"total_count": 3, "jobs": []}

        self.assertTrue(signing_runner.owned_pick(env, read, lagging)[0], "total_count is never trusted")
        pinned = {"name": "sign-nightly-identity-legacy", "status": "in_progress",
                  "labels": [SIDE, "glaeda-runner-cmux13-glaeda-3"]}

        def short_then_runs(path: str) -> dict:  # a short first page of runs, the held one on page 2
            if "/runs?" in path and "nightly.yml" in path and "status=in_progress" in path:
                return {"workflow_runs": [{"id": 7}] if path.endswith("&page=1") else
                        [{"id": 8}] if path.endswith("&page=2") else []}
            if "/runs?" in path:
                return {}
            return {"jobs": [pinned] if "/runs/8/" in path and path.endswith("&page=1") else []}

        self.assertEqual(signing_runner.owned_pick(env, read, short_then_runs)[0], "",
                         "a held job on a later page of runs is counted, however short page 1 is")

        def short_then_jobs(path: str) -> dict:  # a short first page of jobs, the held one on page 2
            if "/runs?" in path:
                return {"workflow_runs": [{"id": 7}]} if ("nightly.yml" in path and "status=in_progress" in path
                                                           and path.endswith("&page=1")) else {}
            return {"jobs": [{"name": "decide", "status": "completed"}] if path.endswith("&page=1") else
                    [pinned] if path.endswith("&page=2") else []}

        self.assertEqual(signing_runner.owned_pick(env, read, short_then_jobs)[0], "",
                         "so is one on a later page of a run's jobs")

        def endless(path: str) -> dict:
            return {"workflow_runs": [{"id": 7}]} if "/runs?" in path else {"jobs": []}

        self.assertEqual(signing_runner.owned_pick(env, read, endless)[0], "",
                         f"a listing past {signing_runner.MAX_PAGES} pages fails closed")
        order: list[str] = []
        signing_runner.owned_pick(env, lambda t, r: order.append("runners") or runners,
                                  lambda path: order.append("jobs") or jobs(path))
        self.assertEqual(order[0], "runners", "the runners are read before the signing jobs are counted")
        held[0]["labels"] = ["blacksmith-6vcpu-macos-26"]  # on Blacksmith: it holds no mini
        self.assertTrue(signing_runner.owned_pick(env, read, jobs)[0])
        held[0].update({"name": "verify-signed-nightly", "labels": [SIDE, "glaeda-runner-cmux13-glaeda-3"]})
        self.assertTrue(signing_runner.owned_pick(env, read, jobs)[0], "only a signing job counts")
        held[0].update({"name": "build-sign-notarize-nightly (arm64)", "status": "completed"})
        self.assertTrue(signing_runner.owned_pick(env, read, jobs)[0], "a finished one holds nothing")
        held[0]["status"] = "queued"
        self.assertEqual(signing_runner.owned_pick(env, read, jobs)[0], "", "a matrix leg counts by its job id")
        held.clear()
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            self.assertEqual(signing_runner.main({**env, "GITHUB_OUTPUT": os.fspath(output)}, ["owned"], read,
                                                 jobs), 0)
            self.assertEqual(output.read_text(), f'owned=["{SIDE}","glaeda-runner-cmux12-glaeda"]\nowned_pool=\n')
            output.unlink()
            self.assertEqual(signing_runner.main({**env, "GITHUB_OUTPUT": os.fspath(output), "ENABLED": "0"}, [],
                                                 read, jobs, lambda t, r: None), 0)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(values["owned"], "")
            self.assertTrue(values["runner"].startswith("blacksmith-"))
            self.assertTrue(values["alternate"].startswith("blacksmith-"))
            # No pool snapshot: the Blacksmith pick is unverified and says so, and takes the size with the
            # most slots rather than vars.MACOS_RUNNER_26 unchecked (HQ#5168).
            self.assertEqual(values["placement"], "unverified")
            self.assertEqual((values["runner"], values["alternate"]),
                             ("blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26"))
            output.unlink()
            fresh = {"generated_at": "2099-01-01T00:00:00Z", "pools": {}}
            self.assertEqual(signing_runner.main({**env, "GITHUB_OUTPUT": os.fspath(output), "ENABLED": "0",
                                                  "CANDIDATE": "blacksmith-12vcpu-macos-26", "SNAPSHOT_TOKEN": "s"}, [], read, jobs,
                                                 lambda t, r: fresh,
                                                 dt.datetime(2099, 1, 1, 0, 1, tzinfo=dt.timezone.utc)), 0)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual((values["runner"], values["placement"]), ("blacksmith-12vcpu-macos-26", "verified"))
            # Both picks share one bounded snapshot read (DRAIN_BY_REMAINING_TIME adds no GitHub read), and a read
            # that fails is kept as well: the Blacksmith pick never retries what the owned pick could not read.
            for result in (fresh, None):
                reads: list[str] = []

                def snapshot(token: str, repo: str) -> Any:
                    reads.append(token)
                    if result is None:
                        raise RuntimeError("HTTP Error 502: Bad Gateway")
                    return result

                output.unlink()
                self.assertEqual(signing_runner.main({**env, "GITHUB_OUTPUT": os.fspath(output),
                                                      "SNAPSHOT_TOKEN": "s"}, [], read, jobs, snapshot,
                                                     dt.datetime(2099, 1, 1, 0, 1, tzinfo=dt.timezone.utc),
                                                     lambda seconds: None), 0)
                self.assertEqual(len(reads), 1 if result else signing_runner.blacksmith_picker.SNAPSHOT_READS,
                                 "one bounded read for the owned and the Blacksmith pick")


    def test_the_cap_counts_every_signing_job_glaeda_holds_the_mini_for(self) -> None:
        """signing_runner.SIGNING_JOBS names the jobs by display name; they must be this file's SIGNING_JOBS."""
        import yaml  # noqa: PLC0415
        named = set()
        for workflow, job_id in SIGNING_JOBS:
            job = yaml.safe_load((ROOT / ".github" / "workflows" / workflow).read_text())["jobs"][job_id]
            named.add((workflow, str(job.get("name") or job_id)))
        self.assertEqual(named, {(workflow, name) for workflow, names in signing_runner.SIGNING_JOBS.items()
                                 for name in names})


class ClaimScriptTests(unittest.TestCase):
    def run_claim(self, tmp: Path, **env: str) -> subprocess.CompletedProcess:
        security = tmp / "security"
        security.write_text('#!/bin/sh\n[ "$1" = delete-keychain ] && rm -f "$KEYCHAINS/$2-db"\n'
                            'echo "$@" >> "$KEYCHAINS/calls"\n')
        security.chmod(0o755)
        environ = {"PATH": "/usr/bin:/bin", "HOME": os.fspath(tmp), "KEYCHAINS": os.fspath(tmp / "keychains"),
                   "CMUX_SECURITY_TOOL": os.fspath(security), "CMUX_KEYCHAIN_DIR": os.fspath(tmp / "keychains"),
                   "CMUX_FLEET_DIR": os.fspath(tmp / "no-fleet"), **env}
        return subprocess.run(["bash", os.fspath(ROOT / CLAIM)], env=environ, capture_output=True, text=True,
                              timeout=30, check=False)

    def test_claim(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            (tmp / "keychains").mkdir()
            ephemeral = self.run_claim(tmp, RUNNER_NAME="blacksmith-6vcpu-macos-26-abc")
            self.assertEqual(ephemeral.returncode, 0, ephemeral.stdout + ephemeral.stderr)
            self.assertIn("is ephemeral", ephemeral.stdout)
            for env in ({"RUNNER_NAME": "cmux12-glaeda-3"}, {"RUNNER_NAME": "cmux12-glaeda"},
                        {"RUNNER_NAME": "mini", "CMUX_FLEET_DIR": raw},
                        {"RUNNER_NAME": "cmux12-glaeda", "GLAEDA_JOB_CLAIM": "light"}):
                with self.subTest(env):
                    refused = self.run_claim(tmp, **env)
                    self.assertEqual(refused.returncode, 1, refused.stdout)
                    self.assertIn("did not give the job the whole mini", refused.stdout)
            for sha in ("", OLD_HOOK, SIGNING_HOOKS[0][:12], "x" * 64, ".*", ".*.*", "[0-9a-f]*",
                        SIGNING_HOOKS[0] + " ", "#", SIGNING_HOOKS[0][:63] + "."):
                with self.subTest(sha=sha):
                    refused = self.run_claim(tmp, RUNNER_NAME="cmux12-glaeda-3", GLAEDA_JOB_CLAIM="exclusive",
                                             GLAEDA_HOOK_SHA256=sha)
                    self.assertEqual(refused.returncode, 1, refused.stdout)
                    self.assertIn("is not one", refused.stdout)
            for sha in SIGNING_HOOKS:
                with self.subTest(listed=sha):
                    passed = self.run_claim(tmp, RUNNER_NAME="cmux12-glaeda-3", GLAEDA_JOB_CLAIM="exclusive",
                                            GLAEDA_HOOK_SHA256=sha)
                    self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
            (tmp / "keychains" / "build.keychain-db").write_text("left by a killed job")
            claimed = self.run_claim(tmp, RUNNER_NAME="cmux12-glaeda-3", GLAEDA_JOB_CLAIM="exclusive",
                                     GLAEDA_HOOK_SHA256=FIRST_SIGNING_HOOK)
            self.assertEqual(claimed.returncode, 0, claimed.stdout + claimed.stderr)
            self.assertIn("holds the whole mini", claimed.stdout)
            self.assertIn("removed the signing keychain build.keychain", claimed.stdout)
            self.assertFalse((tmp / "keychains" / "build.keychain-db").exists())


class SearchListTests(unittest.TestCase):
    """delete puts back the user search list create replaced, and falls back to the login keychain when create could
    not read it or nothing it saw is left, so an owned Mac never keeps the deleted signing keychain as its list."""

    def delete(self, tmp: Path) -> list[str]:
        security = tmp / "security"
        security.write_text('#!/bin/sh\necho "$@" >> "$CALLS"\n')
        security.chmod(0o755)
        env = {"PATH": "/usr/bin:/bin", "HOME": os.fspath(tmp), "CALLS": os.fspath(tmp / "calls"),
               "CMUX_SECURITY_TOOL": os.fspath(security), "CMUX_KEYCHAIN_DIR": os.fspath(tmp / "keychains"),
               "CMUX_SIGNING_KEYCHAIN_STATE_DIR": os.fspath(tmp / "state")}
        done = subprocess.run(["bash", os.fspath(ROOT / "scripts/ci/signing-keychain.sh"), "delete"], env=env,
                              capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        calls = (tmp / "calls").read_text().splitlines() if (tmp / "calls").exists() else []
        (tmp / "calls").unlink(missing_ok=True)
        return [call for call in calls if call.startswith("list-keychains")]

    def test_search_list(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            (tmp / "keychains").mkdir()
            state = tmp / "state"
            state.mkdir()
            login = tmp / "keychains" / "login.keychain-db"
            login.write_text("")
            other = tmp / "keychains" / "other.keychain-db"
            other.write_text("")
            (state / "search-list").write_text(f"{login}\n{other}\n{tmp}/gone.keychain-db\n")
            self.assertEqual(self.delete(tmp), [f"list-keychains -d user -s {login} {other}"])
            self.assertFalse((state / "search-list").exists())
            (state / "search-list.failed").write_text("")
            self.assertEqual(self.delete(tmp), [f"list-keychains -d user -s {login}"], "the capture failed")
            self.assertFalse((state / "search-list.failed").exists())
            (state / "search-list").write_text(f"{tmp}/gone.keychain-db\n")
            self.assertEqual(self.delete(tmp), [f"list-keychains -d user -s {login}"], "nothing it saw is left")
            self.assertEqual(self.delete(tmp), [], "no create in this job: the list is left alone")


class TrustAgentRefreshTests(unittest.TestCase):
    """create restarts the user's trustd agent after the signing keychain joins the search list. An agent running since
    boot never reads a keychain added later, and codesign then fails with errSecInternalComponent ("unable to build
    chain to self-signed root"; two owned minis, every sign-nightly-identity-legacy job, 2026-10-31)."""

    def create(self, tmp: Path, launchctl_script: str) -> tuple[subprocess.CompletedProcess, list[str]]:
        bin_dir = tmp / "bin"
        bin_dir.mkdir(exist_ok=True)
        stubs = {
            # find-certificate -p: the two Developer ID intermediates import-apple-developer-id-intermediates.sh counts
            "security": '#!/bin/sh\necho "security $*" >> "$CALLS"\n'
                        'case "$1" in find-certificate) printf "%s\\n%s\\n" "-----END CERTIFICATE-----" '
                        '"-----END CERTIFICATE-----";; esac\nexit 0\n',
            "launchctl": launchctl_script,
            "uuidgen": "#!/bin/sh\necho 00000000-0000-0000-0000-000000000000\n",
        }
        for name, body in stubs.items():
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": os.fspath(tmp), "CALLS": os.fspath(tmp / "calls"),
               "CMUX_SECURITY_TOOL": os.fspath(bin_dir / "security"),
               "CMUX_LAUNCHCTL_TOOL": os.fspath(bin_dir / "launchctl"),
               "CMUX_KEYCHAIN_DIR": os.fspath(tmp / "keychains"),
               "CMUX_SIGNING_KEYCHAIN_STATE_DIR": os.fspath(tmp / "state"), "RUNNER_TEMP": os.fspath(tmp),
               "APPLE_CERTIFICATE_BASE64": "cDEy", "APPLE_CERTIFICATE_PASSWORD": "pw"}
        done = subprocess.run(["bash", os.fspath(ROOT / "scripts/ci/signing-keychain.sh"), "create"], env=env,
                              capture_output=True, text=True, timeout=30, check=False)
        calls = (tmp / "calls").read_text().splitlines() if (tmp / "calls").exists() else []
        (tmp / "calls").unlink(missing_ok=True)
        return done, calls

    def test_the_agent_restarts_after_the_keychain_joins_the_search_list(self) -> None:
        uid = os.getuid()
        service = f"user/{uid}/com.apple.trustd.agent"
        with tempfile.TemporaryDirectory() as raw:
            done, calls = self.create(Path(raw), '#!/bin/sh\necho "launchctl $*" >> "$CALLS"\nexit 0\n')
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertIn(f"launchctl kickstart -k {service}", calls)
            self.assertLess(calls.index("security list-keychains -d user -s build.keychain"),
                            calls.index(f"launchctl kickstart -k {service}"),
                            "the agent must start again after the search list names the signing keychain")
            self.assertIn("Restarted the trustd agent", done.stdout)
        with tempfile.TemporaryDirectory() as raw:
            # kickstart refused: the pid launchd reports for the label is stopped, and launchd starts it again
            sleeper = subprocess.Popen(["sleep", "30"])
            try:
                script = ('#!/bin/sh\necho "launchctl $*" >> "$CALLS"\n'
                          '[ "$1" = kickstart ] && exit 150\n'
                          f'[ "$1" = print ] && printf "\\tstate = running\\n\\tpid = {sleeper.pid}\\n"\nexit 0\n')
                done, calls = self.create(Path(raw), script)
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertEqual(sleeper.wait(timeout=10), -15, "the agent launchd names gets SIGTERM")
                self.assertIn(f"pid {sleeper.pid}", done.stdout)
            finally:
                if sleeper.poll() is None:
                    sleeper.kill()
        with tempfile.TemporaryDirectory() as raw:
            done, calls = self.create(Path(raw), '#!/bin/sh\nexit 1\n')
            self.assertEqual(done.returncode, 0, "best effort: a refusal never fails the signing step")
            self.assertIn("could not restart the trustd agent", done.stderr)
            self.assertIn("Signing keychain build.keychain is ready", done.stdout)


class ClaimGateTests(unittest.TestCase):
    def test_gate(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw) / "output"
            # curl stands in for raw.githubusercontent.com: it serves this tree's glaeda-signing-hooks.txt for
            # the run's own commit only, records the URL it was asked for, and fails as a 404 for anything else.
            bin_dir = Path(raw) / "bin"
            bin_dir.mkdir()
            served = Path(raw) / "served"
            asked = Path(raw) / "asked"
            curl = bin_dir / "curl"
            curl.write_text('#!/bin/sh\nfor a; do url="$a"; done\necho "$url" >> "$ASKED"\n'
                            '[ "$url" = "$WANT" ] && [ -f "$SERVED" ] && exec cat "$SERVED"\nexit 22\n')
            curl.chmod(0o755)
            run_env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_SHA": "a" * 40}
            want = (f"https://raw.githubusercontent.com/{run_env['GITHUB_REPOSITORY']}/{run_env['GITHUB_SHA']}/"
                    "scripts/ci/glaeda-signing-hooks.txt")

            def gate(**env: str) -> subprocess.CompletedProcess:
                output.write_text("")
                return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", CLAIM_GATE],
                                      env={"PATH": f"{bin_dir}:/usr/bin:/bin", "GITHUB_OUTPUT": os.fspath(output),
                                           "ASKED": os.fspath(asked), "SERVED": os.fspath(served), "WANT": want,
                                           **run_env, **env},
                                      capture_output=True, text=True, timeout=30, check=False)

            served.write_text(SIGNING_HOOKS_FILE.read_text())

            fleet = Path("/Users/Shared/cmux-build-fleet").is_dir()
            if not fleet:
                self.assertEqual(gate(RUNNER_NAME="blacksmith-6vcpu-macos-26-abc").returncode, 0)
                self.assertEqual(output.read_text(), "", "an ephemeral runner claims nothing: its twin never runs")
            for env in ({"RUNNER_NAME": "cmux12-glaeda-3"},
                        {"RUNNER_NAME": "cmux12-glaeda", "GLAEDA_JOB_CLAIM": "light", "GLAEDA_HOOK_SHA256": FIRST_SIGNING_HOOK}):
                with self.subTest(env):
                    refused = gate(**env)
                    self.assertEqual(refused.returncode, 1, refused.stdout)
                    self.assertIn("did not give the job the whole mini", refused.stdout)
                    self.assertEqual(output.read_text(), "")
            owned = {"RUNNER_NAME": "cmux12-glaeda-3", "GLAEDA_JOB_CLAIM": "exclusive"}
            for sha in (None, "", OLD_HOOK, FIRST_SIGNING_HOOK[:12], FIRST_SIGNING_HOOK + "0", "x" * 64):
                with self.subTest(sha=sha):
                    refused = gate(**owned, **({} if sha is None else {"GLAEDA_HOOK_SHA256": sha}))
                    self.assertEqual(refused.returncode, 1, refused.stdout)
                    self.assertIn("is not one scripts/ci/glaeda-signing-hooks.txt lists", refused.stdout)
                    self.assertEqual(output.read_text(), "", "a refused owned attempt leaves claim empty: the twin signs")
            for sha in SIGNING_HOOKS:
                with self.subTest(sha=sha):
                    passed = gate(**owned, GLAEDA_HOOK_SHA256=sha)
                    self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
                    self.assertEqual(output.read_text(), "claim=owned\n")
            self.assertEqual(set(asked.read_text().split()), {want}, "the list is read at the run's own commit only")
            self.assertIn(FIRST_SIGNING_HOOK, SIGNING_HOOKS, "the hook with the leftover-process check passes")
            self.assertNotIn(OLD_HOOK, SIGNING_HOOKS, "the hook from before it is refused")
            # The list read at the run's commit is the one that counts: a hook it adds passes with no workflow edit,
            # a hook it lacks (or a list that cannot be read) is refused.
            new_hook = "b" * 64
            served.write_text(SIGNING_HOOKS_FILE.read_text() + f"{new_hook} a hook glaeda pinned later\n")
            self.assertEqual(gate(**owned, GLAEDA_HOOK_SHA256=new_hook).returncode, 0)
            self.assertEqual(output.read_text(), "claim=owned\n")
            served.write_text(f"# only a note\n{new_hook}\n")
            refused = gate(**owned, GLAEDA_HOOK_SHA256=FIRST_SIGNING_HOOK)
            self.assertEqual(refused.returncode, 1, "a hook the run's commit does not list is refused")
            self.assertEqual(output.read_text(), "")
            served.unlink()
            refused = gate(**owned, GLAEDA_HOOK_SHA256=FIRST_SIGNING_HOOK)
            self.assertEqual(refused.returncode, 1, "an unreadable list refuses: the Blacksmith twin signs")
            self.assertIn("is not one scripts/ci/glaeda-signing-hooks.txt lists", refused.stdout)
            self.assertEqual(output.read_text(), "")
            for sha in ("#", ""):
                with self.subTest(note_line=sha):
                    served.write_text("# a note\n\n")
                    self.assertEqual(gate(**owned, GLAEDA_HOOK_SHA256=sha).returncode, 1)
            self.assertEqual(gate(**owned, GLAEDA_HOOK_SHA256=new_hook,
                                  GITHUB_SHA="c" * 40).returncode, 1, "another commit's list is never read")


class SigningHooksInStepWithGlaedaTests(unittest.TestCase):
    """scripts/ci/glaeda-signing-hooks.txt names only hooks glaeda released with the leftover-process check: each sha
    is one glaeda-disk pins in CMUX_NEXT_DRAIN_HOOK_SHA256, at or after FIRST_SIGNING_HOOK in its order."""

    def glaeda_pins(self) -> list[str]:
        last: Exception | None = None
        for _ in range(3):
            try:
                with urllib.request.urlopen(GLAEDA_DISK_URL, timeout=20) as response:
                    text = response.read().decode()
                break
            except OSError as error:
                last = error
        else:
            self.fail(f"could not read glaeda's pins from {GLAEDA_DISK_URL}: {last}")
        block = re.search(r"CMUX_NEXT_DRAIN_HOOK_SHA256 = frozenset\(\{(.*?)\}\)", text, re.S)
        self.assertIsNotNone(block, "glaeda-disk no longer declares CMUX_NEXT_DRAIN_HOOK_SHA256")
        return re.findall(r'"([0-9a-f]{64})"', block.group(1))

    def test_every_listed_hook_is_one_glaeda_released_with_the_check(self) -> None:
        self.assertEqual(len(SIGNING_HOOKS), len(set(SIGNING_HOOKS)), "a sha is listed twice")
        for sha in SIGNING_HOOKS:
            self.assertRegex(sha, r"^[0-9a-f]{64}$")
        pins = self.glaeda_pins()
        self.assertIn(FIRST_SIGNING_HOOK, pins)
        released = pins[pins.index(FIRST_SIGNING_HOOK):]
        for sha in SIGNING_HOOKS:
            self.assertIn(sha, released, f"{sha} is not a hook glaeda pinned at or after {FIRST_SIGNING_HOOK[:8]}")
        # glaeda #1740's hook was released and never listed, so every owned signing attempt was refused for hours: the
        # hook glaeda pins now (its newest, which minis are moving to) must be listed. HQ's glaeda-signing-hooks-sync
        # workflow opens the PR that adds it.
        self.assertIn(pins[-1], SIGNING_HOOKS,
                      f"glaeda's newest hook {pins[-1]} is not in {SIGNING_HOOKS_FILE.name}; minis on it sign on "
                      "Blacksmith until it is added (add its line, or land the glaeda-signing-hooks sync PR)")


# A 64-hex sha256 in a workflow: a hook named outside the one list.
HEX64 = re.compile(r"(?<![0-9a-fA-F])[0-9a-f]{64}(?![0-9a-fA-F])")


def literal_hook_failures(texts: dict[str, str], hooks: list[str]) -> list[str]:
    """Where a workflow names a glaeda hook itself: any listed (or refused) hook sha anywhere in it, and any 64-hex
    literal in a step that reads GLAEDA_HOOK_SHA256. The claim gates read glaeda-signing-hooks.txt instead."""
    failures = []
    known = set(hooks) | {OLD_HOOK}
    for name, text in sorted(texts.items()):
        for sha in sorted(known):
            if sha in text:
                failures.append(f"{name} names hook {sha[:12]} itself; only {SIGNING_HOOKS_FILE.name} lists hooks")
        document = yaml.safe_load(text)
        jobs = ((document or {}).get("jobs") or {}) if isinstance(document, dict) else {}
        for job_name, job in jobs.items():
            steps = (job.get("steps") or []) if isinstance(job, dict) else []
            for step in steps:
                run = str(step.get("run", "")) if isinstance(step, dict) else ""
                if "GLAEDA_HOOK_SHA256" in run:
                    for sha in sorted(set(HEX64.findall(run)) - known):
                        failures.append(f"{name} {job_name}: a step that reads GLAEDA_HOOK_SHA256 names {sha[:12]} "
                                        f"itself; only {SIGNING_HOOKS_FILE.name} lists hooks")
    return failures


class NoLiteralHookTests(unittest.TestCase):
    """The claim gates carry no hook sha of their own: glaeda-signing-hooks.txt is the one list, read at the run's
    commit, so a new hook is one line there and never four workflow edits (cmux#27408 was the last of those)."""

    def test_no_workflow_names_a_hook(self) -> None:
        texts = {path.name: path.read_text(encoding="utf-8") for path in sorted(WORKFLOWS.glob("*.y*ml"))}
        self.assertEqual(literal_hook_failures(texts, SIGNING_HOOKS), [])

    def test_the_guard_catches_a_literal(self) -> None:
        gate = "jobs:\n  sign:\n    steps:\n      - run: |\n          case \"$GLAEDA_HOOK_SHA256\" in %s) ;; esac\n"
        self.assertTrue(literal_hook_failures({"a.yml": gate % FIRST_SIGNING_HOOK}, [FIRST_SIGNING_HOOK]))
        self.assertTrue(literal_hook_failures({"a.yml": gate % ("d" * 64)}, [FIRST_SIGNING_HOOK]),
                        "an unlisted literal in a gate fails too")
        self.assertTrue(literal_hook_failures({"a.yml": f"env:\n  HOOKS: {FIRST_SIGNING_HOOK}\n"},
                                              [FIRST_SIGNING_HOOK]))
        other = "jobs:\n  x:\n    steps:\n      - run: echo %s\n" % ("e" * 64)
        self.assertEqual(literal_hook_failures({"a.yml": other}, [FIRST_SIGNING_HOOK]), [],
                         "other sha256 literals are not hooks")


if __name__ == "__main__":
    unittest.main()
