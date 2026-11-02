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
   a signing job that starts before it. The one way onto an owned Mac is a
   picker output from scripts/ci/signing_runner.py (Leo, 2026-10-28: the
   release signing jobs may run on our own Macs), on a mini held whole for the
   job; tests/test_ci_signing_owned_mac.py checks those jobs. Two narrow exceptions,
   each proven here rather than listed:
   a. A job glaeda gives the exclusive class (test_ci_signing_owned_mac.SIGNING_JOBS)
      whose first step is that test's CLAIM_GATE may also fall back to the owned
      pool variables in OWNED_ROUTE_VARIABLES (nightly.yml's owned-only legacy sign
      and deltas, Lawrence, 2026-10-30, a7b6a61175c). The gate fails the job on any
      owned Mac without the whole-mini claim before a credential is in reach, however
      the label was chosen, and test_ci_signing_owned_mac.py holds the claim script,
      the always() keychain delete and the rest of its rules for those jobs.
   b. A job in GATED_SECRET_JOBS reads every signing secret only when its mode
      variable says so, and that same condition picks a literal ephemeral label
      before runs-on reads any variable (stable-next.yml's sign: its dry run signs
      ad hoc with no key on an owned Mac; its publish run signs on Blacksmith).
8. A job that signs with the release signer (RELEASE_POOL_SIGNERS) makes no
   keychain: it runs on a literal ubuntu label and hands the certificate only
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
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import signing_runner_variables  # noqa: E402

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
    # The cmux NEXT fresh-home launch smoke (nightly.yml's pre-publish gate and its harness).
    re.compile(r"launch-smoke-gate\.sh"),
    re.compile(r"fresh_home_launch_smoke\.py"),
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
    # Its same-run Blacksmith twin runs the same steps (tests/test_ci_signing_owned_mac.py).
    ("release.yml", "build-sign-notarize-blacksmith"): "scripts/ci/notarize-nightly-dmg.sh",
    ("auto-resume-nightly-notarization.yml", "wait-and-staple"): "scripts/ci/resume-stapled-app-notarization.sh",
    ("auto-resume-nightly-notarization.yml", "staple-outer"): "scripts/ci/resume-stapled-app-notarization.sh",
    ("resume-nightly-notarization.yml", "resume"): "scripts/ci/resume-stapled-app-notarization.sh",
}
# Jobs that sign with the release signer (rule 8), each with the script that gets the certificate.
RELEASE_POOL_SIGNERS = {
    ("nightly.yml", "signer-app"): "scripts/ci/release-signer/sign-app.sh",
    ("nightly.yml", "signer-dmg"): "scripts/ci/release-signer/notarize-dmg.sh",
}
# Jobs that keep bundle code in the signing job, outside the keychain window
# only (rule 1, not rule 6). Each entry names its follow-up.
STEP_LEVEL_ONLY = {
    # Build, sign, notarize and publish are one job; the split into build,
    # sign, verify and publish jobs is a separate change.
    "release.yml build-sign-notarize",
    "release.yml build-sign-notarize-blacksmith",  # its same-run Blacksmith twin, the same steps
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
# live-value check in cmux-next-guards.yml keeps them so, and the cloud overflow
# switch never writes anything else to them. The list lives in
# scripts/ci/signing_runner_variables.py; the check must name exactly it.
EPHEMERAL_RUNNER_VARIABLES = signing_runner_variables.EPHEMERAL_RUNNER_VARIABLES
EPHEMERAL_LABEL = signing_runner_variables.EPHEMERAL_LABEL
# vars.NAME or vars['NAME'] / vars["NAME"], with the literal it falls back to. GitHub reads
# context and variable names without regard to case, so this does too.
RUNNER_VARIABLE = re.compile(
    r"vars(?:\.([A-Za-z0-9_]+)|\[\s*['\"]([A-Za-z0-9_]+)['\"]\s*\])(?:\s*\|\|\s*'([^']*)')?",
    re.IGNORECASE,
)
ANY_VARS = re.compile(r"\bvars\b", re.IGNORECASE)
RUNS_ON_END = re.compile(r"\s*\}\}\s*$")
# Rule 7a: owned pool variables a claim-gated signing job may fall back to.
OWNED_ROUTE_VARIABLES = frozenset({"CI_NIGHTLY_NEXT_BUILD_RUNNER", "CI_SIDE_LANE_RUNNER"})
# Rule 7b: (workflow, job) -> (env variable, value that means "sign with the release key").
GATED_SECRET_JOBS = {("stable-next.yml", "sign"): ("SIGN", "developer-id")}
LIVE_VALUE_CHECK = (".github/workflows/cmux-next-guards.yml", "signing-runner-variables")
LIVE_VALUE_RUNNER = "blacksmith-2vcpu-ubuntu-2404"
# `vars.CI_CLOUD_OVERFLOW_SAVED && '<blacksmith label>' ||`: the overflow failover,
# a boolean record choosing between two literal Blacksmith Linux labels.
OVERFLOW_FAILOVER = re.compile(r"vars\.CI_CLOUD_OVERFLOW_SAVED\s*&&\s*'blacksmith-\d+vcpu-ubuntu-2404'\s*\|\|\s*")
# `vars.NAME == '<label>' && '<label>' ||`: a variable that only chooses between literal labels.
# Its value is compared, never used as the label, so the job still runs on the literal it names.
LITERAL_SELECTOR = re.compile(
    r"vars\.([A-Za-z0-9_]+)\s*==\s*'([^']*)'\s*&&\s*'([^']*)'\s*\|\|\s*", re.IGNORECASE)


def strip_literal_selectors(runs_on: str) -> str:
    """Drop `vars.X == 'L' && 'L' ||` choices whose label L is ephemeral; anything else stays for the checks."""
    return LITERAL_SELECTOR.sub(
        lambda m: "" if m.group(2) == m.group(3) and EPHEMERAL_LABEL.match(m.group(3)) else m.group(0), runs_on)


def claim_gated(name: str, job: dict) -> bool:
    """Rule 7a: glaeda's exclusive class admits the job and its first step is the verbatim claim gate."""
    import test_ci_signing_owned_mac as owned_mac  # late: that module imports this one

    steps = job.get("steps") or []
    first = steps[0] if steps and isinstance(steps[0], dict) else {}
    return (tuple(name.split(" ", 1)) in owned_mac.SIGNING_JOBS
            and first.get("id") == owned_mac.CLAIM_GATE_ID
            and str(first.get("run", "")).strip() == owned_mac.CLAIM_GATE.strip())


def secret_gate_failures(name: str, job: dict) -> list[str] | None:
    """Rule 7b: None when the job is not in GATED_SECRET_JOBS, else what keeps its proof from holding."""
    gate = GATED_SECRET_JOBS.get(tuple(name.split(" ", 1)))
    if not gate:
        return None
    variable, value = gate
    problems = []
    mode = re.fullmatch(r"\$\{\{\s*(.+?)\s*&&\s*'" + re.escape(value) + r"'\s*\|\|\s*'[^']*'\s*\}\}",
                        str((job.get("env") or {}).get(variable, "")).strip())
    if not mode:
        return [f"{name}: env {variable} is not `${{{{ <condition> && '{value}' || '<other>' }}}}`"]
    condition = mode.group(1)
    runs_on = str(job.get("runs-on", ""))
    picked = re.search(re.escape(condition) + r"\s*&&\s*'([^']*)'", runs_on)
    if not picked or not EPHEMERAL_LABEL.match(picked.group(1)) or ANY_VARS.search(runs_on[:picked.start()]):
        problems.append(f"{name}: runs-on does not take a literal ephemeral label on `{condition}` before any variable")
    gated_if = f"env.{variable} == '{value}'"
    gated_value = re.compile(re.escape(gated_if) + r"\s*&&\s*secrets\.[A-Z0-9_]+\s*\|\|\s*'[^']*'\s*\}\}")
    for step in job.get("steps") or []:
        if not isinstance(step, dict) or not SIGNING_SECRET_REFERENCE.search(json.dumps(step)):
            continue
        if gated_if in str(step.get("if", "")):
            continue
        rest = json.dumps({k: v for k, v in step.items() if k != "env"})
        env_ok = all(not SIGNING_SECRET_REFERENCE.search(str(v)) or gated_value.search(str(v))
                     for v in (step.get("env") or {}).values())
        if SIGNING_SECRET_REFERENCE.search(rest) or not env_ok:
            label = step.get("name") or step.get("id") or "<step>"
            problems.append(f"{name}: step {label!r} reads a signing secret outside `{gated_if}`")
    if SIGNING_SECRET_REFERENCE.search(json.dumps(job.get("env") or {})):
        problems.append(f"{name}: job-level env reads a signing secret")
    return problems


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
        runs_on = strip_literal_selectors(str(job.get("runs-on", "")))
        trusted_linux_pool = (
            "fromJSON(vars.RUNNER_POOLS).linux" in runs_on
            and all(label in runs_on for label in (
                "blacksmith-4vcpu-ubuntu-2404",
                "blacksmith-16vcpu-ubuntu-2404",
                "blacksmith-32vcpu-ubuntu-2404",
            ))
            and "contains(fromJSON(" in runs_on
        )
        gated = secret_gate_failures(name, job)
        if gated is not None:
            failures.extend(gated)
            # Proven above: every signing secret sits behind the condition that picks an ephemeral label.
            runs_on = ""
        owned_route = claim_gated(name, job)
        if len(ANY_VARS.findall(runs_on)) != len(RUNNER_VARIABLE.findall(runs_on)):
            failures.append(
                f"{name}: holds a signing secret and reads a repository variable in runs-on in a form this "
                "guard cannot check; write vars.NAME"
            )
        for match in RUNNER_VARIABLE.finditer(runs_on):
            dotted, bracketed, fallback = match.groups()
            variable = (dotted or bracketed).upper()
            if trusted_linux_pool and variable == "RUNNER_POOLS":
                continue
            if owned_route and variable in OWNED_ROUTE_VARIABLES:
                continue
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
    pool_signer = RELEASE_POOL_SIGNERS.get(tuple(name.split(" ", 1)))
    if pool_signer:
        runner = str(job.get("runs-on", ""))
        if "keychain" in text or pool_signer not in text or "ubuntu" not in runner or "macos" in runner:
            failures.append(f"{name}: a release-pool signer runs on a literal ubuntu label, calls {pool_signer} and makes no keychain")
        certificate_steps = [step for step in steps if isinstance(step, dict) and "secrets.APPLE_CERTIFICATE_BASE64" in json.dumps(step)]
        if not certificate_steps or any(pool_signer not in str(step.get("run", "")) for step in certificate_steps):
            failures.append(f"{name}: only the step that runs {pool_signer} may hold the Developer ID certificate")
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
    # pointed at a missing label would leave it queued instead of red. The one
    # variable it may read is the overflow record as a switch between two literal
    # Blacksmith labels (tests/test_ci_blacksmith_linux_failover.py requires it):
    # the record holds no label, so both outcomes stay literal ephemeral runners.
    runs_on = OVERFLOW_FAILOVER.sub("", str(job.get("runs-on", "")))
    if ANY_VARS.search(runs_on) or LIVE_VALUE_RUNNER not in runs_on:
        failures.append(f"{path} {job_name}: runs on the literal {LIVE_VALUE_RUNNER}, never a repository variable")
    steps = job.get("steps") or []
    for step in steps:
        env = {str(k): str(v) for k, v in ((step or {}).get("env") or {}).items()}
        run = str((step or {}).get("run", ""))
        if all(env.get(v, "").replace(" ", "") == "${{vars.%s}}" % v for v in EPHEMERAL_RUNNER_VARIABLES) \
                and "blacksmith-" in run and "ubuntu-" in run and "exit 1" in run:
            # The step loops over exactly the shared list, so a variable added there is checked live too.
            loop = re.search(r"^\s*for\s+name\s+in\s+([A-Z0-9_ ]+?)\s*;\s*do\b", run, re.MULTILINE)
            looped = tuple(loop.group(1).split()) if loop else ()
            if sorted(looped) != sorted(EPHEMERAL_RUNNER_VARIABLES) or \
                    sorted(n for n in env if n.isupper() and env[n].startswith("${{")) != sorted(EPHEMERAL_RUNNER_VARIABLES):
                failures.append(
                    f"{path} {job_name}: checks {', '.join(looped) or 'no variables'}, not exactly "
                    f"{', '.join(EPHEMERAL_RUNNER_VARIABLES)} (scripts/ci/signing_runner_variables.py)"
                )
            return
    failures.append(
        f"{path} {job_name}: no step fails when {', '.join(EPHEMERAL_RUNNER_VARIABLES)} hold a label other than "
        "blacksmith-* or ubuntu-*; signing jobs read them (rule 7)"
    )


def check_literal_selectors(failures: list[str]) -> None:
    """A selector is dropped only when it picks the literal it compares against, and that literal is ephemeral."""
    cases = {
        "${{ vars.LINUX_RUNNER == 'blacksmith-16vcpu-ubuntu-2404' && 'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-32vcpu-ubuntu-2404' }}":
            "${{ 'blacksmith-32vcpu-ubuntu-2404' }}",
        "${{ vars.LINUX_RUNNER == 'blacksmith-16vcpu-ubuntu-2404' && 'glaeda-std-xcode-26.6' || 'blacksmith-32vcpu-ubuntu-2404' }}": None,
        "${{ vars.X == 'glaeda-std-xcode-26.6' && 'glaeda-std-xcode-26.6' || 'blacksmith-32vcpu-ubuntu-2404' }}": None,
    }
    for runs_on, expected in cases.items():
        if strip_literal_selectors(runs_on) != (runs_on if expected is None else expected):
            failures.append(f"strip_literal_selectors mishandles {runs_on}")


def main() -> int:
    failures: list[str] = []
    check_literal_selectors(failures)
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
