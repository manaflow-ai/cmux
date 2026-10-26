#!/usr/bin/env python3
"""No code from an app bundle runs while a CI signing keychain exists.

A signing job imports the Developer ID certificate into a keychain. While that
keychain exists and is unlocked, any process in the job can sign with the
identity. Bundle code (a launch smoke, the bundled CLI, the diff sidecar
handshake) must therefore run only after the keychain is deleted.
scripts/ci/signing-keychain.sh owns the keychain's lifetime, and the scripts
that run bundle code refuse to start while it exists
(scripts/ci/lib/signing-runtime-guard.sh). This guard holds the same rule
statically, so a reordered step fails in review and not on a release day:

1. In every workflow job, walk the steps and their commands in order. A
   command that creates the keychain opens a signing window; a command that
   deletes it closes the window. A command that runs bundle code inside an
   open window fails the guard.
2. A job that creates a keychain deletes it again in an `if: always()` step.
3. A job that creates the Developer ID keychain does so through
   scripts/ci/signing-keychain.sh, and holds no secret or job token in its
   job-level `env:` (each step names the secrets it needs).
4. An inline `set-keychain-settings -lut N` keeps N within the job timeout
   and at 90 minutes or less (the iOS archive signs at its end), and the
   managed keychain's idle lock stays at 600 seconds or less.
5. The signing scripts keep their own order: notarize-nightly-dmg.sh deletes
   the keychain after the DMG signature and before its smokes, the helper
   resume deletes it before the continuation runs the app, sign-cmux-bundle.sh
   defers the sidecar handshake while the keychain exists, and every script
   that runs bundle code calls the runtime guard first.

6. A job that holds signing, notarization or release-publishing material (or
   runs in a release environment) runs no bundle code at all, not only outside the keychain
   window: a process that bundle code leaves running survives into the later
   steps of the same job. Bundle code runs in jobs without secrets on literal
   ephemeral runner labels: a job without that material that runs bundle code
   on what a release job made (it needs one, directly or through others) runs
   on a literal label, alone or after the fork short-circuit. The one
   exception is OWNED_VERIFY_JOBS: exactly the job and runs-on named there,
   which may take an owned Mac free now, holding no secret, outside any
   environment, not continue-on-error, in a fresh work directory it removes
   in an always() step.
   The notarization scripts run in such jobs only
   with their launch smokes deferred (CMUX_DEFER_LAUNCH_SMOKES) or skipped.
   STEP_LEVEL_ONLY lists the jobs that still rely on rule 1 alone.
7. A job that holds a signing secret runs on a literal runner label, not a
   repository variable that could move it onto a reused machine.
8. A job that signs on Linux with rcodesign (LINUX_PEM_SIGNERS) makes no
   keychain: it runs on a literal Linux label and hands the certificate only
   to its signer script, which keeps the key in its own temporary directory.

Not covered by rule 6: other environments and credentials (artifacts,
package registries, CI cache, Sentry, Cloudflare, Vercel, CEF R2) and a job
token with write scopes. Rule 6 is about signing, notarization and release
publication.

Every step is treated as if it runs. Keep each delete in a step that runs
whenever the matching create ran (`if: always()` or the same condition).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"

CREATE = re.compile(r"signing-keychain\.sh\s+create\b|\bsecurity\s+create-keychain\b")
DELETE = re.compile(
    r"signing-keychain\.sh\s+delete\b|\bsecurity\s+delete-keychain\b"
    # These scripts sign and then delete the keychain themselves (rule 5).
    r"|scripts/ci/notarize-nightly-dmg\.sh|scripts/ci/resume-helper-notarization\.sh"
    r"|scripts/ci/resume-stapled-app-notarization\.sh"
)
BUNDLE_CODE = [
    re.compile(r"smoke-launch-macos-app\.sh"),
    re.compile(r"smoke-signed-app-cli\.sh"),
    re.compile(r"test_cli_version_memory_guard\.py"),
    re.compile(r"scripts/ci/smoke-dmg\.sh"),
    re.compile(r"install-cmux-tui-client\.sh"),
    re.compile(r"test_bundled_ghostty_theme_picker_helper\.sh"),
    re.compile(r"verify_remote_daemon_release\.py(?=.*--verify-cli)"),
    re.compile(r"verify-diff-sidecar-artifact\.sh(?!.*--static-only)"),
]
LUT = re.compile(r"set-keychain-settings\s+-lut\s+(\d+)")
SECRET_OR_TOKEN = re.compile(r"secrets\.|secrets\[|github\.token")
# Rule 6 covers signing, notarization and release-publishing material, and
# the protected environments that hold it. Build jobs that hold only a CI cache
# or symbol-upload credential are out of scope.
RELEASE_SECRET_REFERENCE = re.compile(
    r"secrets(\.|\[\s*(format\(\s*)?['\"])(APPLE_|ASC_API_|IOS_|SPARKLE_|NIGHTLY_SPARKLE_|CMUX_RELEASE_APP_"
    r"|CONTENT_SIGNING_|CF_R2_|NIGHTLY_NEXT_R2_|HOMEBREW_TAP_TOKEN)"
)
RELEASE_ENVIRONMENT = re.compile(r"\b(release|release-next|content-signing|nightly-next-promote|release-surface-ack)\b")
# The CodeRouter release signs one CLI binary with a keychain at an absolute
# path and runs nothing from it; it keeps its own inline import.
INLINE_DEVELOPER_ID_KEYCHAINS = {("coderouter-release.yml", "build")}
# Jobs whose Developer ID keychain a script makes with signing-keychain.sh
# create just before its signature: notarize-nightly-dmg.sh (the DMG around
# the stapled app) and resume-stapled-app-notarization.sh (the same DMG in a
# continuation). Rule 5 checks the order inside those scripts.
SCRIPT_MADE_KEYCHAINS = {
    ("nightly.yml", "build-sign-notarize-nightly"): "scripts/ci/notarize-nightly-dmg.sh",
    ("release.yml", "build-sign-notarize"): "scripts/ci/notarize-nightly-dmg.sh",
    ("auto-resume-nightly-notarization.yml", "wait-and-staple"): "scripts/ci/resume-stapled-app-notarization.sh",
    ("auto-resume-nightly-notarization.yml", "staple-outer"): "scripts/ci/resume-stapled-app-notarization.sh",
    ("resume-nightly-notarization.yml", "resume"): "scripts/ci/resume-stapled-app-notarization.sh",
}
# Jobs that sign on Linux (rule 8), each with the script that gets the certificate.
LINUX_PEM_SIGNERS = {
    ("cmux-next-dev-daily.yml", "sign"): "scripts/ci/rcodesign-sign-bundle-dev.sh",
}
# Rule 6's one exception: a secret-free verify job that attempt 1 may run on the
# owned Mac its placement job picked (Leo, 2026-10-24: owned Macs before
# Blacksmith), with exactly this runs-on.
OWNED_VERIFY_JOBS = {
    ("cmux-next-dev-daily.yml", "verify"): "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
    "(github.run_attempt == 1 && needs.runner.outputs.label || 'blacksmith-6vcpu-macos-26') }}",
}
LITERAL_EPHEMERAL_RUNNER = re.compile(
    r"(?:macos|ubuntu)-[0-9.]+(?:-arm)?|blacksmith-[0-9]+vcpu-(?:macos|ubuntu)-[0-9a-z]+"
    r"|\$\{\{ github\.repository_owner != 'manaflow-ai' && '(?:macos|ubuntu)-[0-9.]+' "
    r"\|\| '(?:blacksmith-[0-9]+vcpu-(?:macos|ubuntu)-[0-9a-z]+|(?:macos|ubuntu)-[0-9.]+)' \}\}")
# Jobs that keep bundle code in the signing job, outside the keychain window
# only (rule 1, not rule 6). Each entry names its follow-up.
STEP_LEVEL_ONLY = {
    # Build, sign, notarize and publish are one job; the split into build,
    # sign, verify and publish jobs is a separate change.
    "release.yml build-sign-notarize",
}
# Scripts that launch the app unless their launch smokes are deferred.
SMOKING_SCRIPTS = re.compile(
    r"scripts/ci/notarize-nightly-dmg\.sh|scripts/ci/resume-nightly-notarization\.sh|scripts/ci/resume-helper-notarization\.sh"
    r"|scripts/ci/resume-stapled-app-notarization\.sh|scripts/ci/finish-stapled-app-dmgs\.sh"
)
SIGNING_SECRET_REFERENCE = re.compile(r"secrets\.(APPLE_|ASC_API_|IOS_|SPARKLE_|NIGHTLY_SPARKLE_|CMUX_RELEASE_APP_|CONTENT_SIGNING_)")
VARIABLE_RUNNER = re.compile(r"vars\.[A-Z0-9_]*RUNNER")


def commands(run: str) -> list[str]:
    """The run script as logical commands: continuations joined, comments dropped."""
    joined = re.sub(r"\\\n\s*", " ", run)
    return [line.strip() for line in joined.splitlines() if line.strip() and not line.strip().startswith("#")]


def deferred_step(step: dict) -> bool:
    env = {str(k): str(v) for k, v in (step.get("env") or {}).items()}
    return env.get("CMUX_DEFER_LAUNCH_SMOKES") == "true" or env.get("CMUX_SKIP_NOTARIZATION") == "true"


def check_job(name: str, job: dict, failures: list[str]) -> None:
    steps = job.get("steps") or []
    open_window = ""
    created = False
    cleaned_up = False
    for step in steps:
        if not isinstance(step, dict):
            continue
        label = step.get("name") or step.get("id") or step.get("uses") or "<step>"
        condition = str(step.get("if", ""))
        for command in commands(str(step.get("run", ""))):
            if CREATE.search(command):
                open_window = label
                created = True
                continue
            if DELETE.search(command):
                open_window = ""
                if "always()" in condition:
                    cleaned_up = True
                continue
            smokes = SMOKING_SCRIPTS.search(command) and not deferred_step(step)
            if open_window and (smokes or any(pattern.search(command) for pattern in BUNDLE_CODE)):
                failures.append(
                    f"{name}: step {label!r} runs bundle code while the signing keychain from "
                    f"{open_window!r} exists: {command[:120]}"
                )
    if created and not cleaned_up:
        failures.append(f"{name}: creates a signing keychain but no `if: always()` step deletes it")

    holds_secrets = bool(RELEASE_SECRET_REFERENCE.search(json.dumps(job))) or bool(
        RELEASE_ENVIRONMENT.search(json.dumps(job.get("environment") or "")))
    if holds_secrets and name not in STEP_LEVEL_ONLY:
        for step in steps:
            if not isinstance(step, dict):
                continue
            label = step.get("name") or step.get("id") or step.get("uses") or "<step>"
            deferred = deferred_step(step)
            for command in commands(str(step.get("run", ""))):
                if any(pattern.search(command) for pattern in BUNDLE_CODE):
                    failures.append(
                        f"{name}: step {label!r} runs bundle code in a job that holds secrets; "
                        f"move it to a job without secrets: {command[:120]}"
                    )
                elif SMOKING_SCRIPTS.search(command) and not deferred:
                    failures.append(
                        f"{name}: step {label!r} runs a notarization script that launches the app; "
                        "set CMUX_DEFER_LAUNCH_SMOKES: \"true\" and smoke in a job without secrets"
                    )
    if SIGNING_SECRET_REFERENCE.search(json.dumps(job)) and VARIABLE_RUNNER.search(str(job.get("runs-on", ""))):
        failures.append(f"{name}: holds a signing secret but picks its runner from a repository variable; use a literal ephemeral label")

    text = json.dumps(job)
    pem_signer = LINUX_PEM_SIGNERS.get(tuple(name.split(" ", 1)))
    if pem_signer:
        runner = str(job.get("runs-on", ""))
        if "keychain" in text or pem_signer not in text or "ubuntu" not in runner or "macos" in runner:
            failures.append(f"{name}: a Linux signer runs on a literal Linux label, calls {pem_signer} and makes no keychain")
        certificate_steps = [step for step in steps if isinstance(step, dict) and "secrets.APPLE_CERTIFICATE_BASE64" in json.dumps(step)]
        if any(pem_signer not in str(step.get("run", "")) for step in certificate_steps):
            failures.append(f"{name}: only the step that runs {pem_signer} may hold the Developer ID certificate")
        if SECRET_OR_TOKEN.search(json.dumps(job.get("env") or {})):
            failures.append(f"{name}: job-level env holds a secret or the job token; set it on the steps that use it")
    elif "secrets.APPLE_CERTIFICATE_BASE64" in text and name not in {
        f"{workflow} {job_name}" for workflow, job_name in INLINE_DEVELOPER_ID_KEYCHAINS
    }:
        script = SCRIPT_MADE_KEYCHAINS.get(tuple(name.split(" ", 1)))
        if "signing-keychain.sh create" not in text and not (script and script in text):
            failures.append(f"{name}: imports the Developer ID certificate without scripts/ci/signing-keychain.sh create")
        if "security import" in text:
            failures.append(f"{name}: imports a certificate inline; use scripts/ci/signing-keychain.sh create")
        job_env = json.dumps(job.get("env") or {})
        if SECRET_OR_TOKEN.search(job_env):
            failures.append(f"{name}: job-level env holds a secret or the job token; set it on the steps that use it")

    # GitHub's default job timeout is 360 minutes.
    timeout_minutes = job.get("timeout-minutes", 360)
    for match in LUT.finditer(text):
        seconds = int(match.group(1))
        if not isinstance(timeout_minutes, int) or seconds > timeout_minutes * 60 or seconds > 5400:
            failures.append(
                f"{name}: keychain idle lock {seconds}s is longer than the job timeout "
                f"({timeout_minutes} minutes); lock it sooner"
            )


def holds_release_material(job: dict) -> bool:
    return bool(RELEASE_SECRET_REFERENCE.search(json.dumps(job))) or bool(
        RELEASE_ENVIRONMENT.search(json.dumps(job.get("environment") or "")))


def runs_bundle_code(job: dict) -> bool:
    return any(
        any(pattern.search(command) for pattern in BUNDLE_CODE)
        or (SMOKING_SCRIPTS.search(command) and not deferred_step(step))
        for step in job.get("steps") or [] if isinstance(step, dict)
        for command in commands(str(step.get("run", ""))))


def check_verify_runners(workflow: str, jobs: dict, failures: list[str]) -> None:
    """Rule 6: bundle code run on a release job's output stays on literal ephemeral labels."""
    def upstream(name: str, seen: set[str]) -> set[str]:
        needs = jobs.get(name, {}).get("needs") or []
        for other in [needs] if isinstance(needs, str) else needs:
            if other in jobs and other not in seen:
                seen.add(other)
                upstream(other, seen)
        return seen

    for name, job in jobs.items():
        if not isinstance(job, dict) or holds_release_material(job) or not runs_bundle_code(job):
            continue
        if not any(holds_release_material(jobs[other]) for other in upstream(name, set())):
            continue
        runs_on = str(job.get("runs-on", ""))
        allowed = OWNED_VERIFY_JOBS.get((workflow, name))
        if allowed is None:
            if not LITERAL_EPHEMERAL_RUNNER.fullmatch(runs_on):
                failures.append(f"{workflow} {name}: runs bundle code on a release job's output; "
                                f"use a literal ephemeral runner label, not {runs_on}")
            continue
        steps = [step for step in job.get("steps") or [] if isinstance(step, dict)]
        text = json.dumps(job)
        fresh = [i for i, step in enumerate(steps) if 'rm -rf "$dir"' in str(step.get("run", ""))
                 and '"$RUNNER_TEMP/' in str(step.get("run", ""))]
        removed = [i for i, step in enumerate(steps) if "always()" in str(step.get("if", ""))
                   and 'rm -rf "$VERIFY_DIR"' in str(step.get("run", ""))]
        if (runs_on != allowed or "secrets." in text or "github.token" in text or "environment" in job
                or not fresh or not removed or fresh[0] > removed[-1] or "continue-on-error" in text):
            failures.append(f"{workflow} {name}: the owned verify job runs on exactly {allowed}, holds no secret, "
                            "token or environment, works in a fresh $RUNNER_TEMP directory it removes in an "
                            "always() step, and is not continue-on-error")


def self_test_verify_runners() -> list[str]:
    """Mutations rule 6's exception must refuse: it allows one job and one runs-on, nothing wider."""
    (workflow, name), allowed = next(iter(OWNED_VERIFY_JOBS.items()))
    good = {
        "sign": {"environment": "release", "steps": [{"run": "sign"}]},
        name: {"needs": "sign", "runs-on": allowed, "steps": [
            {"run": 'dir="$RUNNER_TEMP/v"\nrm -rf "$dir"'},
            {"run": "./scripts/verify-diff-sidecar-artifact.sh app --require-signed"},
            {"if": "always()", "run": 'rm -rf "$VERIFY_DIR"'}]},
    }
    problems = []
    if failures_of(workflow, good):
        problems.append(f"the owned verify job itself was refused: {failures_of(workflow, good)}")
    owned = "${{ needs.runner.outputs.label || 'blacksmith-6vcpu-macos-26' }}"
    mutations = {
        "another runs-on for the allowed job": (workflow, {**good, name: {**good[name], "runs-on": owned}}),
        "the allowed runs-on in another workflow": ("nightly.yml", good),
        "the allowed runs-on on another job": (workflow, {"sign": good["sign"], "other": good[name]}),
        "a secret in the allowed job": (workflow, {**good, name: {**good[name], "env": {"T": "${{ secrets.X }}"}}}),
        "no always() removal": (workflow, {**good, name: {**good[name], "steps": good[name]["steps"][:2]}}),
        "continue-on-error": (workflow, {**good, name: {**good[name], "continue-on-error": True}}),
    }
    for what, (where, jobs) in mutations.items():
        if not failures_of(where, jobs):
            problems.append(f"rule 6 self-test: {what} was allowed")
    return problems


def failures_of(workflow: str, jobs: dict) -> list[str]:
    found: list[str] = []
    check_verify_runners(workflow, jobs, found)
    return found


def read_lines(path: str, failures: list[str]) -> list[str]:
    file = ROOT / path
    if not file.is_file():
        failures.append(f"{path}: missing")
        return []
    return file.read_text(encoding="utf-8").splitlines()


def index_of(lines: list[str], pattern: str, *, last: bool = False) -> int:
    hits = [number for number, line in enumerate(lines) if pattern in line and not line.lstrip().startswith("#")]
    if not hits:
        return -1
    return hits[-1] if last else hits[0]


def check_scripts(failures: list[str]) -> None:
    tool = "\n".join(read_lines("scripts/ci/signing-keychain.sh", failures))
    timeout = re.search(r'CMUX_SIGNING_KEYCHAIN_TIMEOUT:-(\d+)', tool)
    if not timeout or int(timeout.group(1)) > 600:
        failures.append("scripts/ci/signing-keychain.sh: the default idle lock must be 600 seconds or less")

    dmg = read_lines("scripts/ci/notarize-nightly-dmg.sh", failures)
    last_sign = index_of(dmg, '"$CODESIGN_TOOL" --force', last=True)
    delete = index_of(dmg, '"$SIGNING_KEYCHAIN_TOOL" delete')
    first_smoke = index_of(dmg, 'launch_smokes "$APP_PATH"')
    if not (0 <= last_sign < delete < first_smoke):
        failures.append(
            "scripts/ci/notarize-nightly-dmg.sh: delete the signing keychain after the last codesign "
            f"and before the first smoke (sign={last_sign} delete={delete} smoke={first_smoke})"
        )
    # The DMG around the stapled app (CMUX_STAPLE_APP_IN_DMG) is signed with a
    # keychain the script creates after Apple's wait; it is deleted again
    # before the second submission and before any smoke.
    create = index_of(dmg, '"$SIGNING_KEYCHAIN_TOOL" create')
    if create >= 0:
        later_delete = next(
            (number for number, line in enumerate(dmg)
             if number > create and '"$SIGNING_KEYCHAIN_TOOL" delete' in line and not line.lstrip().startswith("#")),
            -1,
        )
        if not (create < later_delete < first_smoke):
            failures.append(
                "scripts/ci/notarize-nightly-dmg.sh: delete the keychain it creates for the stapled-app DMG "
                f"before the first smoke (create={create} delete={later_delete} smoke={first_smoke})"
            )

    resume = read_lines("scripts/ci/resume-helper-notarization.sh", failures)
    delete = index_of(resume, '"$SIGNING_KEYCHAIN_TOOL" delete')
    continuation = index_of(resume, '"$STAPLED_TOOL"')
    if not (0 <= delete < continuation):
        failures.append("scripts/ci/resume-helper-notarization.sh: delete the signing keychain before the continuation runs the app")

    stapled = read_lines("scripts/ci/resume-stapled-app-notarization.sh", failures)
    # The package tool makes the keychain just before its signature
    # (CMUX_PACKAGE_CREATES_KEYCHAIN) and deletes it after; the wrapper deletes
    # it again before the second continuation.
    first = index_of(stapled, '"$RESUME_TOOL" "$STATE_FILE" "$APP_PATH" "$DMG_RELEASE"', last=True)
    creates = index_of(stapled, "CMUX_PACKAGE_CREATES_KEYCHAIN=true")
    package = index_of(stapled, '"$PACKAGE_TOOL"')
    delete = index_of(stapled, '"$SIGNING_KEYCHAIN_TOOL" delete', last=True)
    continuation = index_of(stapled, 'continue_stapled "$OUTER_STATE"', last=True)
    own_create = index_of(stapled, '"$SIGNING_KEYCHAIN_TOOL" create')
    if own_create >= 0 or not (0 <= first < creates < package < delete < continuation):
        failures.append(
            "scripts/ci/resume-stapled-app-notarization.sh: let the package tool make the signing keychain "
            "after the first continuation, and delete it before the second continuation "
            f"(first={first} creates={creates} package={package} delete={delete} continuation={continuation} own_create={own_create})"
        )

    sign = "\n".join(read_lines("scripts/sign-cmux-bundle.sh", failures))
    if '"$SIGNING_KEYCHAIN_TOOL" is-present' not in sign or "SIDECAR_CHECK+=(--static-only)" not in sign:
        failures.append("scripts/sign-cmux-bundle.sh: defer the diff sidecar handshake while a signing keychain exists")

    for script, before in (
        ("scripts/smoke-launch-macos-app.sh", 'EXECUTABLE_PATH="'),
        ("scripts/smoke-signed-app-cli.sh", 'EXECUTABLE_PATH="'),
        ("scripts/verify-diff-sidecar-artifact.sh", 'HANDSHAKE="$("$BINARY" handshake)"'),
    ):
        lines = read_lines(script, failures)
        guard = index_of(lines, "cmux_signing_runtime_guard")
        target = index_of(lines, before)
        if not (0 <= guard < target):
            failures.append(f"{script}: call cmux_signing_runtime_guard before the first bundle binary runs")

    daemon = read_lines("scripts/verify_remote_daemon_release.py", failures)
    guard = index_of(daemon, "    refuse_with_signing_keychain()")
    run = index_of(daemon, "subprocess.run(")
    if not (0 <= guard < run):
        failures.append("scripts/verify_remote_daemon_release.py: refuse --verify-cli while a signing keychain exists")


def main() -> int:
    failures: list[str] = []
    signing_jobs = 0
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            continue
        for job_name, job in (document.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            if "keychain" in json.dumps(job):
                signing_jobs += 1
            check_job(f"{path.name} {job_name}", job, failures)
        check_verify_runners(path.name, document.get("jobs") or {}, failures)
    for (workflow, name) in OWNED_VERIFY_JOBS:
        document = yaml.safe_load((WORKFLOWS / workflow).read_text(encoding="utf-8")) or {}
        if name not in (document.get("jobs") or {}):
            failures.append(f"{workflow} {name}: OWNED_VERIFY_JOBS names a job that does not exist")
    failures += self_test_verify_runners()
    check_scripts(failures)
    if signing_jobs < 5:
        failures.append(f"found only {signing_jobs} keychain jobs; this guard is reading the wrong tree")
    if failures:
        print("Bundle code must not run while a CI signing keychain exists:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"OK: {signing_jobs} keychain jobs delete the signing keychain before any bundle code runs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
