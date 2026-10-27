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
   ephemeral runner labels. The notarization scripts run in such jobs only
   with their launch smokes deferred (CMUX_DEFER_LAUNCH_SMOKES) or skipped.
   STEP_LEVEL_ONLY lists the jobs that still rely on rule 1 alone.
7. A job that holds a signing secret runs on an ephemeral runner (Blacksmith or
   GitHub's hosted Linux; "blacksmith runners we can simply trust", Leo,
   2026-10-24), never a reused machine. Its runs-on names either a literal
   ephemeral label or one of EPHEMERAL_RUNNER_VARIABLES, whose fallback literal
   is ephemeral too. A test cannot read a variable's live value, so
   cmux-next-guards.yml's signing-runner-variables job (on a literal Blacksmith
   runner) checks it on every feat-cmux-next pull request and push: pointing one
   of those variables at an owned mini turns it red. It detects; it does not stop
   a signing job that starts before it.

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
# Run blocks moved out of a workflow into their own script (inline_step_scripts).
STEP_SCRIPT = re.compile(r"scripts/ci/nightly-steps/[A-Za-z0-9_.-]+\.sh")
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
    # nightly-next recovery signs the DMG around the stapled app (feat-cmux-next).
    ("nightly.yml", "recover-nightly-next-notarization"): "scripts/ci/notarize-nightly-dmg.sh",
    ("release.yml", "build-sign-notarize"): "scripts/ci/notarize-nightly-dmg.sh",
    ("auto-resume-nightly-notarization.yml", "wait-and-staple"): "scripts/ci/resume-stapled-app-notarization.sh",
    ("auto-resume-nightly-notarization.yml", "staple-outer"): "scripts/ci/resume-stapled-app-notarization.sh",
    ("resume-nightly-notarization.yml", "resume"): "scripts/ci/resume-stapled-app-notarization.sh",
}
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
# secrets.NAME, secrets['NAME'] and secrets[format('NAME...', ...)], as RELEASE_SECRET_REFERENCE reads them.
SIGNING_SECRET_REFERENCE = re.compile(
    r"secrets(\.|\[\s*(format\(\s*)?\\?['\"])(APPLE_|ASC_API_|IOS_|SPARKLE_|NIGHTLY_SPARKLE_|CMUX_RELEASE_APP_|CONTENT_SIGNING_)",
    re.IGNORECASE,
)
# Rule 7. These repository variables hold only ephemeral runner labels; the
# live-value check in cmux-next-guards.yml keeps them so. Add a variable here
# only together with that check.
EPHEMERAL_RUNNER_VARIABLES = ("LINUX_RUNNER", "MACOS_RUNNER_26")
EPHEMERAL_LABEL = re.compile(r"^(blacksmith-|ubuntu-)[a-z0-9.-]+$")
# vars.NAME or vars['NAME'] / vars["NAME"], with the literal it falls back to. GitHub reads
# context and variable names without regard to case, so this does too.
RUNNER_VARIABLE = re.compile(
    r"vars(?:\.([A-Za-z0-9_]+)|\[\s*['\"]([A-Za-z0-9_]+)['\"]\s*\])(?:\s*\|\|\s*'([^']*)')?",
    re.IGNORECASE,
)
ANY_VARS = re.compile(r"\bvars\b", re.IGNORECASE)
RUNS_ON_END = re.compile(r"\s*\}\}\s*$")
LIVE_VALUE_CHECK = (".github/workflows/cmux-next-guards.yml", "signing-runner-variables")
LIVE_VALUE_RUNNER = "blacksmith-2vcpu-ubuntu-2404"


def commands(run: str) -> list[str]:
    """The run script as logical commands: continuations joined, comments dropped."""
    joined = re.sub(r"\\\n\s*", " ", run)
    return [line.strip() for line in joined.splitlines() if line.strip() and not line.strip().startswith("#")]


def deferred_step(step: dict) -> bool:
    env = {str(k): str(v) for k, v in (step.get("env") or {}).items()}
    return env.get("CMUX_DEFER_LAUNCH_SMOKES") == "true" or env.get("CMUX_SKIP_NOTARIZATION") == "true"


def inline_step_scripts(job: dict, missing: list[str] | None = None) -> dict:
    """The job with each moved run block (STEP_SCRIPT) expanded where its step invokes it.

    nightly.yml keeps under GitHub's size limit by moving run blocks into
    scripts/ci/nightly-steps (#25879); their commands still run in the step, in
    the order of the invocation, so every rule reads them there. Comment lines
    invoke nothing. A script that does not exist is added to `missing`.
    """
    steps = []
    for step in job.get("steps") or []:
        if isinstance(step, dict) and STEP_SCRIPT.search(str(step.get("run", ""))):
            lines = []
            for line in re.sub(r"\\\n\s*", " ", str(step["run"])).splitlines():
                lines.append(line)
                if line.strip().startswith("#"):
                    continue
                for script in STEP_SCRIPT.findall(line):
                    path = ROOT / script
                    if path.is_file():
                        lines.extend(path.read_text(encoding="utf-8").splitlines())
                    elif missing is not None:
                        missing.append(script)
            step = {**step, "run": "\n".join(lines)}
        steps.append(step)
    return {**job, "steps": steps}


def check_job(name: str, job: dict, failures: list[str]) -> None:
    missing: list[str] = []
    job = inline_step_scripts(job, missing)
    for script in missing:
        failures.append(f"{name}: runs {script}, which does not exist")
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
    if SIGNING_SECRET_REFERENCE.search(json.dumps(job)):
        runs_on = str(job.get("runs-on", ""))
        if len(ANY_VARS.findall(runs_on)) != len(RUNNER_VARIABLE.findall(runs_on)):
            failures.append(
                f"{name}: holds a signing secret and reads a repository variable in runs-on in a form this "
                "guard cannot check; write vars.NAME"
            )
        for match in RUNNER_VARIABLE.finditer(runs_on):
            dotted, bracketed, fallback = match.groups()
            variable = (dotted or bracketed).upper()
            if variable not in EPHEMERAL_RUNNER_VARIABLES:
                failures.append(
                    f"{name}: holds a signing secret but picks its runner from vars.{variable}; use a literal "
                    f"ephemeral label or one of {', '.join(EPHEMERAL_RUNNER_VARIABLES)}"
                )
            # The variable and its literal close the expression (`... || vars.X || 'blacksmith-...' }}`),
            # so nothing after them (an `&&`, another selector) can replace the label they give.
            elif not (fallback and EPHEMERAL_LABEL.match(fallback) and RUNS_ON_END.match(runs_on, match.end())):
                failures.append(
                    f"{name}: holds a signing secret and reads vars.{variable} other than as the expression's "
                    "last choice `vars.NAME || '<blacksmith-* or ubuntu-* label>' }}`"
                )

    text = json.dumps(job)
    if "secrets.APPLE_CERTIFICATE_BASE64" in text and name not in {
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


def check_live_runner_variables(failures: list[str]) -> None:
    """Rule 7's live half: a guard job fails when an ephemeral-only variable holds another label."""
    path, job_name = LIVE_VALUE_CHECK
    document = yaml.safe_load((ROOT / path).read_text(encoding="utf-8")) or {}
    job = (document.get("jobs") or {}).get(job_name) or {}
    # The check's own runner must not come from the variables it checks: a variable
    # pointed at a missing label would leave it queued instead of red.
    if ANY_VARS.search(str(job.get("runs-on", ""))) or LIVE_VALUE_RUNNER not in str(job.get("runs-on", "")):
        failures.append(f"{path} {job_name}: runs on the literal {LIVE_VALUE_RUNNER}, never a repository variable")
    steps = job.get("steps") or []
    for step in steps:
        env = {str(k): str(v) for k, v in ((step or {}).get("env") or {}).items()}
        run = str((step or {}).get("run", ""))
        if all(env.get(v, "").replace(" ", "") == "${{vars.%s}}" % v for v in EPHEMERAL_RUNNER_VARIABLES) \
                and "blacksmith-" in run and "ubuntu-" in run and "exit 1" in run:
            return
    failures.append(
        f"{path} {job_name}: no step fails when {', '.join(EPHEMERAL_RUNNER_VARIABLES)} hold a label other than "
        "blacksmith-* or ubuntu-*; signing jobs read them (rule 7)"
    )


def main() -> int:
    failures: list[str] = []
    check_live_runner_variables(failures)
    signing_jobs = 0
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            continue
        for job_name, job in (document.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            if "keychain" in json.dumps(inline_step_scripts(job)):
                signing_jobs += 1
            check_job(f"{path.name} {job_name}", job, failures)
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
