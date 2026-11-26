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
7. A job that holds a signing secret may run on any of our runners, owned or ephemeral. The rule that kept
   it on an ephemeral one (and its live check, cmux-next-guards.yml's signing-runner-variables) is gone:
   Leo, 2026-11-19, "if 99.99999% of the code is ours, there's literally nothing to be concerned about if we
   literally dont allow forks to run on ours automatically". A fork run never reaches an owned runner and
   gets no secrets (tests/test_ci_fork_runner_routing.py). Two helpers stay for test_ci_signing_owned_mac.py,
   whose whole-mini claim keeps two signing keychains off one mini:
   a. claim_gated() and owned_route_failures(): a job glaeda gives the exclusive class
      (test_ci_signing_owned_mac.GLAEDA_EXCLUSIVE_JOBS) whose first step is that test's CLAIM_GATE, routed
      through the owned pool variables in OWNED_ROUTE_VARIABLES, has the claim script before its first
      secret and an empty job `env:`.
   b. A job in GATED_SECRET_JOBS reads every signing secret only when its mode variable says so, and that
      same condition picks a literal ephemeral label before runs-on reads any variable (stable-next.yml's
      sign: its dry run signs ad hoc with no key on an owned Mac), so it needs no claim.
8. A job that signs with the release signer (RELEASE_SIGNER_SCRIPT) makes no
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
from collections.abc import Iterator
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import signing_runner_variables  # noqa: E402
import workflow_jobs  # noqa: E402
from shell_invocations import must_run, run_when_reached  # noqa: E402  (every caller here CREDITS a step: uncertain is not run)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import gh_expressions  # noqa: E402  (finds each ${{ }}: a regex cuts at a }} in a string)

CREATE = re.compile(r"signing-keychain\.sh\s+create\b|\bsecurity\s+create-keychain\b")
DELETE = re.compile(
    r"signing-keychain\.sh\s+delete\b|\bsecurity\s+delete-keychain\b"
    # These scripts sign and then delete the keychain themselves (rule 5).
    r"|scripts/ci/notarize-nightly-dmg\.sh|scripts/ci/resume-stapled-app-notarization\.sh"
    r"|scripts/ci/nightly-steps/next-pkg\.sh"
)
# The scripts DELETE names that delete the keychain themselves.
SELF_DELETING_SCRIPTS = ("scripts/ci/notarize-nightly-dmg.sh", "scripts/ci/resume-helper-notarization.sh",
                         "scripts/ci/resume-stapled-app-notarization.sh", "scripts/ci/nightly-next-pkg.sh")


def deletes_keychain(words: list[str]) -> bool:
    """Whether one command (program first, as must_run() gives it) deletes a keychain: the program itself, not an
    argument (`echo ./scripts/ci/signing-keychain.sh delete` deletes nothing)."""
    program = words[0].rsplit("/", 1)[-1]
    return ((program == "signing-keychain.sh" and words[1:2] == ["delete"])
            or (program == "security" and words[1:2] == ["delete-keychain"])
            or words[0] in SELF_DELETING_SCRIPTS)


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
GITHUB_TOKEN = re.compile(r"\bgithub\.token\b", re.IGNORECASE)
# Rule 6 covers signing, notarization and release-publishing material, and
# the protected environments that hold it. Build jobs that hold only a CI cache
# or symbol-upload credential are out of scope.
# Secret names are read by tests/workflow_jobs.py in every form (secrets.X, secrets['X'], secrets["X"], any case,
# toJSON(secrets), secrets: inherit); an index it cannot read (secrets[format(...)]) counts as every secret.
SIGNING_SECRET_PREFIXES = ("APPLE_", "ASC_API_", "IOS_", "SPARKLE_", "NIGHTLY_SPARKLE_", "CMUX_RELEASE_APP_",
                           "CONTENT_SIGNING_")
RELEASE_SECRET_PREFIXES = (*SIGNING_SECRET_PREFIXES, "CF_R2_", "NIGHTLY_NEXT_R2_", "HOMEBREW_TAP_TOKEN")
RELEASE_ENVIRONMENT = re.compile(r"\b(release|release-next|content-signing|nightly-next-promote|release-surface-ack)\b")
# Jobs that keep an inline Developer ID import (none since the CodeRouter release
# left with CodeRouter, 2026-11-25). A choice, so a list: every job that imports
# the Developer ID certificate inline is named here or fails rule 3, and every
# entry still imports it inline (inline_keychain_classification).
INLINE_DEVELOPER_ID_KEYCHAINS: set[tuple[str, str]] = set()
# Scripts that make the Developer ID keychain with signing-keychain.sh create
# just before their signature: notarize-nightly-dmg.sh (the DMG around the
# stapled app) and resume-stapled-app-notarization.sh (the same DMG in a
# continuation, through its package tool) and nightly-next-pkg.sh (nightly-next-pkg's installer
# package, #54859). Rule 5 checks the order inside each.
# A job that runs one of them needs no create of its own (script_made_keychain());
# the jobs are read from the workflows, not listed.
KEYCHAIN_MAKING_SCRIPTS = ("scripts/ci/notarize-nightly-dmg.sh", "scripts/ci/resume-stapled-app-notarization.sh",
                           "scripts/ci/nightly-next-pkg.sh")
# Rule 8's signer scripts. A job whose certificate step runs one of them signs
# with the release signer (release_pool_signer()); the jobs are read from the
# workflows, not listed. None does today: nightly.yml's signer-app, signer-dmg,
# legacy-signer-app and legacy-signer-dmg, which the old list named, are gone.
RELEASE_SIGNER_SCRIPT = re.compile(r"scripts/ci/release-signer/[A-Za-z0-9_.-]+\.sh")
# Jobs that keep bundle code in the signing job, outside the keychain window
# only (rule 1, not rule 6). Each entry names its follow-up. A waiver, so a list:
# every job that runs bundle code while it holds release material is here or
# fails rule 6, and every entry still does (step_level_classification).
STEP_LEVEL_ONLY = {
    # Build, sign, notarize and publish are one job; the split into build,
    # sign, verify and publish jobs is a separate change.
    "release.yml build-sign-notarize",
    "release.yml build-sign-notarize-blacksmith",  # its same-run Blacksmith twin, the same steps
    # nightly-next on one Mac (Leo, 2026-11-12): build, sign, notarize and publish in one job by design.
    "nightly.yml nightly-next-one",
}
# Scripts that launch the app unless their launch smokes are deferred.
SMOKING_SCRIPTS = re.compile(
    r"scripts/ci/notarize-nightly-dmg\.sh|scripts/ci/resume-nightly-notarization\.sh"
    r"|scripts/ci/resume-stapled-app-notarization\.sh|scripts/ci/finish-stapled-app-dmgs\.sh"
)


def reads_secret_prefixed(value: object, prefixes: tuple[str, ...]) -> bool:
    """value (a job, a step, an env mapping or one string) reads a secret whose name starts with one of prefixes,
    or every secret at once."""
    names = workflow_jobs.secret_names(value)
    return workflow_jobs.ALL_SECRETS in names or any(name.startswith(prefixes) for name in names)


def signing_secret(value: object) -> bool:
    return reads_secret_prefixed(value, SIGNING_SECRET_PREFIXES)


def release_secret(value: object) -> bool:
    return reads_secret_prefixed(value, RELEASE_SECRET_PREFIXES)


def secret_or_token(value: object) -> bool:
    """value reads any secret or the job token."""
    return bool(workflow_jobs.secret_names(value)) or any(GITHUB_TOKEN.search(text)
                                                          for text in workflow_jobs.strings(value))
# The repository variables that name an ephemeral runner (scripts/ci/signing_runner_variables.py): a signing job
# that reads one is not on an owned Mac, so test_ci_signing_owned_mac.py's whole-mini claim does not apply to it.
EPHEMERAL_RUNNER_VARIABLES = signing_runner_variables.EPHEMERAL_RUNNER_VARIABLES
EPHEMERAL_LABEL = signing_runner_variables.EPHEMERAL_LABEL
# Literal labels that are ephemeral too: a one-job JIT GCE VM, deleted after its job, that only cmuxterm-hq
# gha-runners serve and no PR job may name (tests/test_ci_nightly_labels_reserved.py). GitHub-hosted runners start
# nothing in manaflow-ai (Leo, 2026-11-21 00:14Z: "the ci must flow"), so the nightly's secret-holding Linux jobs
# take it on every attempt. Admitted as a runs-on literal only: an ephemeral-only variable still holds only
# blacksmith-* or ubuntu-* (signing_runner_variables.allowed_value), and a persistent runner or a mini never matches.
JIT_EPHEMERAL_LABELS = frozenset({"cmux-gcp-nightly-jit-x64"})


def ephemeral_literal(label: str | None) -> bool:
    """Whether a literal runs-on label names an ephemeral runner: EPHEMERAL_LABEL or a one-job JIT VM label."""
    label = (label or "").strip()
    return bool(EPHEMERAL_LABEL.match(label)) or label in JIT_EPHEMERAL_LABELS
# vars.NAME or vars['NAME'] / vars["NAME"], with the literal it falls back to. GitHub reads
# context and variable names without regard to case, so this does too.
RUNNER_VARIABLE = re.compile(
    r"vars(?:\.([A-Za-z0-9_]+)|\[\s*['\"]([A-Za-z0-9_]+)['\"]\s*\])(?:\s*\|\|\s*'([^']*)')?",
    re.IGNORECASE,
)
ANY_VARS = re.compile(r"\bvars\b", re.IGNORECASE)
# Rule 7a: owned pool variables a claim-gated signing job may route through.  Each holds a glaeda fleet label:
# runner_label_policy's NO_HOSTED_MAC_VARIABLES keeps a GitHub-hosted Mac out of every one, and
# cloud_overflow_switch.py writes none of them (they are in neither SWITCHED_VARIABLES nor
# OVERRIDABLE_VARIABLES).  So the job lands either on an ephemeral runner or on an owned Mac, where the claim
# gate refuses it without glaeda's exclusive claim.  CI_NIGHTLY_SIGN_RUNNER and CI_NIGHTLY_SIGNING_POOL are the
# narrowest: runner_label_policy holds both to `glaeda-trusted-next-signing`, which glaeda gives only to the
# trusted main runners of a mini with runner.trustedNextSigning, and its hook admits exactly nightly.yml's
# exclusive class there on the nightly-next push (glaeda scripts/glaeda-cmux-runner-hook TRUSTED_NEXT_SIGNING);
# tests/test_nightly_signing_on_cmux15.py pins the route.
OWNED_ROUTE_VARIABLES = frozenset({
    "CI_NIGHTLY_NEXT_BUILD_RUNNER", "CI_SIDE_LANE_RUNNER", "CI_NIGHTLY_SIGN_RUNNER", "CI_NIGHTLY_SIGNING_POOL",
})
# Rule 7a's second half: the claim script, which refuses an owned Mac without the claim and clears a keychain a
# killed job left, runs before the first step that names a secret.
CLAIM_SCRIPT = "scripts/ci/signing-runner-claim.sh"
# A step condition that runs the step even after an earlier step failed, so coming after the claim is not
# enough: `if: always()` (or failure()/cancelled()) on a secret-bearing step would hand it the credential on
# an owned Mac whose claim the gate had just refused. The same matcher test_ci_signing_owned_mac.py uses.
RUNS_AFTER_FAILURE = re.compile(r"\b(?:always|failure|cancelled)\s*\(")
# GitHub prefixes `success() &&` only to a condition that names no status function, so naming `success()` is not
# enough either: `!success()`, `success() || x` and `success() && a || b` (`||` binds looser than `&&`) all run
# after a failed step (router-review F1 at 25cfca8de04). Only an explicit leading `success() &&` over an operand
# with no status function and no `||` keeps the implicit guard.
STATUS_FUNCTION = re.compile(r"\b(?:success|always|failure|cancelled)\s*\(", re.IGNORECASE)
GUARDED_BY_SUCCESS = re.compile(r"^success\(\s*\)(?:\s*&&\s*(?P<rest>.+))?$", re.IGNORECASE | re.DOTALL)


def runs_after_failure(condition: object) -> bool:
    """Whether a step with this `if:` can run after an earlier step of its job failed."""
    text = str(condition or "").strip()
    expression = gh_expressions.EXPRESSION.fullmatch(text)
    text = (expression.group(1) if expression else text).strip()
    if not STATUS_FUNCTION.search(text):
        return False
    guarded = GUARDED_BY_SUCCESS.match(text)
    if not guarded:
        return True
    rest = guarded.group("rest") or ""
    return bool(STATUS_FUNCTION.search(rest)) or "||" in rest
# The script has to be *run*, unconditionally, from a trusted path, and its failure has to fail the job.  No
# pattern over shell text can say that: `if false; then bash <path>; fi` and `bash <path> || true` both hold a
# plausible-looking invocation while skipping the stale-keychain cleanup or swallowing a refused claim, and an
# optional directory prefix takes `evil/scripts/ci/signing-runner-claim.sh` as readily as the real thing.  So
# this takes the shape CLAIM_GATE already has, which test_ci_signing_owned_mac.py compares word for word: the
# step's whole `run:` must be one of these exact commands.  Nothing else is accepted, so every control-flow,
# chaining, redirection, quoting and path trick fails by construction instead of by a sharper pattern.  A new
# call site adds its exact line here, a reviewed act.  Each form is the real path and nothing else: bare (a
# path with a slash is run directly, never looked up on PATH), `./`, or bash on the path or on one of the two
# sparse-checkout copies (`.nightly-signing-control/` and `.publish-tooling/`) two nightly jobs run it from.
CLAIM_COMMANDS = frozenset({
    CLAIM_SCRIPT,
    f"./{CLAIM_SCRIPT}",
    f"bash {CLAIM_SCRIPT}",
    f"bash .nightly-signing-control/{CLAIM_SCRIPT}",
    f"bash .publish-tooling/{CLAIM_SCRIPT}",
})


def runs_the_claim_script(step: dict, job: dict | None = None) -> bool:
    """Whether this step's whole `run:` is one of CLAIM_COMMANDS, run by bash from the workspace root.

    CLAIM_COMMANDS are paths relative to the checkout, so a `working-directory` (the step's, or JOB's
    `defaults.run`) would run another tree's copy of the script: router-review F1 at 9aacf011fd8.

    Detection only: a step found here may still carry an `if:`, because test_ci_signing_owned_mac.py allows one
    (cmux-next-dev-daily's sign skips its whole body with no source artifact) and relies on the unconditional
    first-step gate instead.  owned_route_failures() is what refuses a conditional or failure-swallowing claim
    on an owned route."""
    if str(step.get("shell", "bash")) != "bash":
        return False
    if "working-directory" in step or "working-directory" in (((job or {}).get("defaults") or {}).get("run") or {}):
        return False
    return str(step.get("run", "")).strip() in CLAIM_COMMANDS


# These declared pools contain only ephemeral Blacksmith members.  Secret-bearing
# jobs may use them as their pool-backed fallback; the hosted pools are excluded.
EPHEMERAL_POOL_KEYS = frozenset({
    "linux_2", "linux_4", "linux_8", "linux_16", "linux_32", "linux_arm64",
    "macos_15", "macos_26", "macos_26_large", "macos_latest", "windows",
})
# Rule 7b: (workflow, job) -> (env variable, value that means "sign with the release key").
GATED_SECRET_JOBS = {("stable-next.yml", "sign"): ("SIGN", "developer-id")}
# The waiver is a choice (it lets the job's other mode take any runner), so it stays a list; but every job with rule
# 7b's shape (mode_gated_secret()) is in it or here with a reason, and every entry still has the shape
# (check_gated_secret_classification). None today.
GATED_SECRET_EXEMPT: dict[tuple[str, str], str] = {}
# `${{ <condition> && '<value>' || '<other>' }}`: a job env mode variable, as secret_gate_failures() reads it. The
# pattern reads the contents of one whole expression (mode_env_value()), which gh_expressions finds.
MODE_ENV_VALUE = re.compile(r"(.+?)\s*&&\s*'([^']*)'\s*\|\|\s*'[^']*'", re.DOTALL)


def mode_env_value(raw: object, value: str | None = None) -> re.Match | None:
    """`raw` as `${{ <condition> && '<value>' || '<other>' }}` (with `value` given, that value), else None."""
    whole = gh_expressions.STRIPPED.fullmatch(str(raw).strip())
    if whole is None:
        return None
    if value is None:
        return MODE_ENV_VALUE.fullmatch(whole.group(1))
    return re.fullmatch(r"(.+?)\s*&&\s*'" + re.escape(value) + r"'\s*\|\|\s*'[^']*'", whole.group(1), re.DOTALL)


# `vars.NAME == '<label>' && '<label>' ||`: a variable that only chooses between literal labels.
# Its value is compared, never used as the label, so the job still runs on the literal it names.
LITERAL_SELECTOR = re.compile(
    r"vars\.([A-Za-z0-9_]+)\s*==\s*'([^']*)'\s*&&\s*'([^']*)'\s*\|\|\s*", re.IGNORECASE)


# `vars.MODE != '' &&`: a variable tested only for being set, which switches a mode on while some *other*
# expression gives the label (nightly.yml's one-mini mode, Lawrence, 2026-11-04, 723c3bcbd96:
# `vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_SIGN_RUNNER` runs the signing jobs on the one nightly mini's
# signing runner). Its own value can never become the runs-on label, so it is a condition, not a route.
# Two narrowings keep the drop from hiding a route, both of them necessary:
#   * only a variable named in MODE_VARIABLES is dropped, so an unknown `vars.BAD != '' && ...` still fails as
#     an unchecked route, exactly as it did before this was added;
#   * only a clause that selects another `vars.` reference, or the signer's own label MODE_SIGNER_LABEL, is
#     dropped, so what the mode selects still faces every check below. A clause selecting any other literal
#     (`vars.CI_NIGHTLY_MINI != '' && 'macos-26'`) is left in place, and the mode variable then fails the guard,
#     because nothing here validates literal labels: the fork route puts a hosted `macos-26` literal in every
#     nightly runs-on, so they cannot simply be checked.
# Only that one occurrence is dropped: a mode variable also read as a label elsewhere still faces every check.
MODE_VARIABLES = frozenset({"CI_NIGHTLY_MINI"})
# The one literal a mode clause may select: the label runner_label_policy holds CI_NIGHTLY_SIGN_RUNNER and
# CI_NIGHTLY_SIGNING_POOL to, which glaeda gives only to the trusted signing runners and whose hook admits only
# nightly.yml's exclusive class (rule 7a). Since aa9f145374c the signing jobs name it directly:
# `vars.CI_NIGHTLY_MINI != '' && 'glaeda-trusted-next-signing'`.
MODE_SIGNER_LABEL = "glaeda-trusted-next-signing"
PRESENCE_CONDITION = re.compile(
    r"vars\.(" + "|".join(sorted(MODE_VARIABLES)) + r")\s*!=\s*''\s*&&\s*(?=vars\.|'"
    + re.escape(MODE_SIGNER_LABEL) + r"'\s*(?:\|\||\}\}))", re.IGNORECASE)


def strip_literal_selectors(runs_on: str) -> str:
    """Drop `vars.X == 'L' && 'L' ||` choices whose label L is ephemeral, `vars.X == 'E' && 'J' ||` ones whose
    compared value E is an ephemeral label and whose label J a one-job JIT VM (the nightly's hosted switch, now
    routed to the JIT label), and `vars.X != '' &&` presence tests (PRESENCE_CONDITION), which give no label;
    anything else stays for the checks."""
    def dropped(m: re.Match) -> bool:
        compared, label = m.group(2), m.group(3)
        if compared == label:
            return ephemeral_literal(label)
        return label in JIT_EPHEMERAL_LABELS and bool(EPHEMERAL_LABEL.match(compared))

    stripped = LITERAL_SELECTOR.sub(lambda m: "" if dropped(m) else m.group(0), runs_on)
    return PRESENCE_CONDITION.sub("", stripped)


# What may follow an owned route variable that gives the label: the next alternative or the expression's end.
# Anything else (`!= ''`, `== 'x'`, `&&`) makes it a condition, and what it selects is then the label: router-review
# F1 at 1e9095d099b: `vars.CI_NIGHTLY_SIGN_RUNNER != '' && 'macos-26'` passed while the label was a hosted Mac.
GIVES_LABEL = re.compile(r"\s*(?:\|\||\}\})")


def owned_label(runs_on: str, match: re.Match) -> bool:
    """Rule 7a's waiver: this RUNNER_VARIABLE match is an OWNED_ROUTE_VARIABLES name that gives the runs-on label
    itself, never one only tested in a condition."""
    return ((match.group(1) or match.group(2)).upper() in OWNED_ROUTE_VARIABLES
            and bool(GIVES_LABEL.match(runs_on, match.end())))


def claim_gated(name: str, job: dict) -> bool:
    """Rule 7a: glaeda's exclusive class admits the job and its first step is the verbatim claim gate."""
    import test_ci_signing_owned_mac as owned_mac  # late: that module imports this one

    steps = job.get("steps") or []
    first = steps[0] if steps and isinstance(steps[0], dict) else {}
    return (tuple(name.split(" ", 1)) in owned_mac.GLAEDA_EXCLUSIVE_JOBS
            and first.get("id") == owned_mac.CLAIM_GATE_ID
            and str(first.get("run", "")).strip() == owned_mac.claim_gate_for(name.split(" ", 1)[0]).strip())


def owned_route_failures(name: str, job: dict) -> list[str]:
    """Rule 7a: what keeps a claim-gated job's owned route from being proven, beyond the first-step gate.

    The gate itself fails the job on an owned Mac without glaeda's exclusive claim, so these are the rules that
    keep a credential out of reach until the claim is re-checked by the script: one step's whole `run:` is a
    verbatim CLAIM_COMMANDS line (so no comment, echo, conditional, chained, backgrounded or redirected form
    stands in for it), it is unconditional and its failure fails the job, it comes before the first step that
    names a secret, no secret-bearing step overrides the failure with `always()`, `failure()` or `cancelled()`
    (which would run it anyway after a refused claim), and the job's `env:` names none (every step, the gate
    included, holds it).
    tests/test_ci_signing_owned_mac.py holds the same order for the jobs it covers (every keychain and Sparkle-key
    job); this holds it here for the rest of the exclusive class, which makes no keychain."""
    steps = [step for step in job.get("steps") or [] if isinstance(step, dict)]
    failures = []
    claim = next((index for index, step in enumerate(steps) if runs_the_claim_script(step, job)), None)
    first_secret = next((index for index, step in enumerate(steps)
                         if signing_secret(step)), None)
    if claim is None:
        failures.append(f"{name}: takes an owned route without a step whose whole run: is one of "
                        f"{', '.join(sorted(CLAIM_COMMANDS))}, run from the workspace root (no working-directory)")
    else:
        # `<=`: the claim step's own env is set before its script runs (router-review F2 at 9aacf011fd8).
        if first_secret is not None and first_secret <= claim:
            failures.append(f"{name}: step {first_secret} names a signing secret before or in the claim step "
                            f"({claim})")
        # The claim must be neither skippable nor survivable: an `if:` could leave the stale-keychain cleanup
        # and the claim re-check unrun, and continue-on-error would let a refused claim reach the key steps.
        if str(steps[claim].get("if", "")).strip():
            failures.append(f"{name}: the claim step ({claim}) is conditional (if: {steps[claim]['if']}); "
                            "on an owned route it runs unconditionally")
        if str(steps[claim].get("continue-on-error", "false")).strip().lower() != "false":
            failures.append(f"{name}: the claim step ({claim}) has continue-on-error, so a refused claim "
                            "would not fail the job")
        # Coming after the claim is not enough: a secret-bearing step whose condition survives a failure runs
        # anyway on an owned Mac whose claim the gate refused, so the credential is in reach regardless.
        for index, step in enumerate(steps):
            if (signing_secret(step)
                    and runs_after_failure(step.get("if"))):
                label = step.get("name") or step.get("id") or "<step>"
                failures.append(f"{name}: step {index} {label!r} names a signing secret and runs after a "
                                f"failed claim (if: {step.get('if')})")
    if signing_secret(workflow_jobs.resolve(job).env):
        failures.append(f"{name}: job-level env names a signing secret, which every step (the gate's too) holds")
    return failures


def secret_gate_failures(name: str, job: dict) -> list[str] | None:
    """Rule 7b: None when the job is not in GATED_SECRET_JOBS, else what keeps its proof from holding."""
    gate = GATED_SECRET_JOBS.get(tuple(name.split(" ", 1)))
    if not gate:
        return None
    variable, value = gate
    problems = []
    mode = mode_env_value(workflow_jobs.resolve(job).env.get(variable, ""), value)
    if not mode:
        return [f"{name}: env {variable} is not `${{{{ <condition> && '{value}' || '<other>' }}}}`"]
    condition = mode.group(1)
    cells = workflow_jobs.runs_on_cells(job)
    if cells is None:
        return [f"{name}: runs-on has a matrix value nothing resolves, so no condition is shown to pick its label"]
    runs_on = "\n".join(cells)
    picked = re.search(re.escape(condition) + r"\s*&&\s*'([^']*)'", runs_on)
    picked_pool = re.search(re.escape(condition) + r"\s*&&\s*fromJSON\(vars\.RUNNER_POOLS\)\.([A-Za-z0-9_]+)", runs_on)
    picked_ok = (picked and ephemeral_literal(picked.group(1))) or (picked_pool and picked_pool.group(1) in EPHEMERAL_POOL_KEYS)
    picked_at = picked.start() if picked else (picked_pool.start() if picked_pool else 0)
    if not picked_ok or ANY_VARS.search(runs_on[:picked_at]):
        problems.append(f"{name}: runs-on does not take a literal ephemeral label on `{condition}` before any variable")
    gated_if = f"env.{variable} == '{value}'"
    gated_value = re.compile(re.escape(gated_if) + r"\s*&&\s*secrets\.[A-Z0-9_]+\s*\|\|\s*'[^']*'\s*\}\}")
    for step in job.get("steps") or []:
        if not isinstance(step, dict) or not signing_secret(step):
            continue
        if gated_if in str(step.get("if", "")):
            continue
        env_ok = all(not signing_secret(v) or gated_value.search(str(v))
                     for v in (step.get("env") or {}).values())
        if signing_secret({k: v for k, v in step.items() if k != "env"}) or not env_ok:
            label = step.get("name") or step.get("id") or "<step>"
            problems.append(f"{name}: step {label!r} reads a signing secret outside `{gated_if}`")
    if signing_secret(workflow_jobs.resolve(job).env):
        problems.append(f"{name}: job-level env reads a signing secret")
    return problems



def mode_gated_secret(job: dict) -> tuple[str, str] | None:
    """Rule 7b's shape: (VAR, value) when the job env sets VAR from a condition (MODE_ENV_VALUE) and a step reads a
    signing secret under `env.VAR == 'value'` (its `if:` or the value itself); None otherwise."""
    modes = {str(name): match.group(2) for name, raw in workflow_jobs.resolve(job).env.items()
             if (match := mode_env_value(raw))}
    for step in job.get("steps") or []:
        if not isinstance(step, dict) or not signing_secret(step):
            continue
        for variable, value in re.findall(r"\benv\.([A-Za-z0-9_]+)\s*==\s*'([^']*)'", json.dumps(step)):
            if modes.get(variable) == value:
                return variable, value
    return None


def gated_secret_classification(documents: dict[str, dict], listed: dict | None = None,
                                exempt: dict | None = None) -> tuple[list[str], int]:
    """Every job with rule 7b's shape is in `listed` (GATED_SECRET_JOBS, with the variable and value it is gated on)
    or in `exempt` (GATED_SECRET_EXEMPT), and every entry of either names a job with that shape. Returns the failures
    and how many jobs have the shape."""
    listed = GATED_SECRET_JOBS if listed is None else listed
    exempt = GATED_SECRET_EXEMPT if exempt is None else exempt
    failures, shaped, seen = [], 0, set()
    for workflow, document in documents.items():
        for name, job in ((document or {}).get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            key, label, gate = (workflow, name), f"{workflow} {name}", mode_gated_secret(job)
            shaped += gate is not None
            if key in exempt or key in listed:
                seen.add(key)
            if key in exempt:
                if key in listed:
                    failures.append(f"{label}: both in GATED_SECRET_JOBS and GATED_SECRET_EXEMPT")
                elif gate is None:
                    failures.append(f"{label}: in GATED_SECRET_EXEMPT but has no mode-gated signing secret; drop it")
            elif key in listed:
                if gate != listed[key]:
                    failures.append(f"{label}: GATED_SECRET_JOBS says its signing secrets are gated on "
                                    f"{listed[key]}, but the workflow gates them on {gate}")
            elif gate is not None:
                failures.append(f"{label}: reads a signing secret only under env.{gate[0]} == '{gate[1]}' (rule 7b's "
                                "shape) but is not in GATED_SECRET_JOBS or GATED_SECRET_EXEMPT with a reason")
    for key in sorted((set(listed) | set(exempt)) - seen):
        failures.append(f"{key[0]} {key[1]}: listed for rule 7b, but no such job")
    return failures, shaped


def with_job(documents: dict[str, dict], workflow: str, name: str, job: dict) -> dict[str, dict]:
    """Every workflow document as it is, plus `job` as `name` in `workflow`: a fixture is the whole tree with one job
    added, never a subset, so the other entries of every list still find their jobs."""
    out = dict(documents)
    out[workflow] = {**documents[workflow], "jobs": {**documents[workflow]["jobs"], name: job}}
    return out


def bracketed(value: object) -> object:
    """value with every `secrets.NAME` written `secrets['NAME']`, the form an unlisted job can hide behind."""
    if isinstance(value, str):
        return re.sub(r"\bsecrets\.([A-Za-z_][A-Za-z0-9_]*)", r"secrets['\1']", value)
    if isinstance(value, workflow_jobs.Job):
        out = workflow_jobs.copy_job(value, {key: bracketed(item) for key, item in value.items()})
        out.inherited_env = bracketed(value.inherited_env)
        return out
    if isinstance(value, dict):
        return {key: bracketed(item) for key, item in value.items()}
    if isinstance(value, list):
        return [bracketed(item) for item in value]
    return value


def gated_secret_fixture_failures(documents: dict[str, dict]) -> list[str]:
    """Rule 7b's guard against fixtures built on every document: a copy of a listed job under a new id, in dot and in
    bracket form, must be named and nothing else; the same copy listed with its gate must leave the guard green."""
    problems = []
    workflow, name = next(iter(sorted(GATED_SECRET_JOBS)))
    variable, value = GATED_SECRET_JOBS[(workflow, name)]
    listed_job = documents[workflow]["jobs"][name]
    for form, job in (("dot", listed_job), ("bracket", bracketed(listed_job))):
        expected = (f"{workflow} sign-split-fixture: reads a signing secret only under env.{variable} == '{value}' "
                    "(rule 7b's shape) but is not in GATED_SECRET_JOBS or GATED_SECRET_EXEMPT with a reason")
        found = gated_secret_classification(with_job(documents, workflow, "sign-split-fixture", job))[0]
        if found != [expected]:
            problems.append(f"rule 7b: the classification guard does not name an unlisted mode-gated job ({form} "
                            f"form): {found}")
    fixture = with_job(documents, workflow, "sign-split-fixture", bracketed(listed_job))
    found = gated_secret_classification(fixture, {**GATED_SECRET_JOBS, (workflow, "sign-split-fixture"): (variable, value)})[0]
    if found:
        problems.append(f"rule 7b: a second mode-gated job that is listed fails the guard: {found}")
    return problems


def check_gated_secret_classification(documents: dict[str, dict], failures: list[str]) -> None:
    """Rule 7b's list against the workflows, a non-empty scan, and the fixtures (gated_secret_fixture_failures)."""
    found, shaped = gated_secret_classification(documents)
    failures.extend(found)
    if not GATED_SECRET_JOBS or shaped < len(GATED_SECRET_JOBS):
        failures.append(f"rule 7b: found {shaped} mode-gated signing jobs for {len(GATED_SECRET_JOBS)} entries; "
                        "is this the right tree?")
    for reason in GATED_SECRET_EXEMPT.values():
        if not reason.strip():
            failures.append("rule 7b: a GATED_SECRET_EXEMPT entry gives no reason")
    failures.extend(gated_secret_fixture_failures(documents))

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
    # A copy keeps the workflow env it inherits (tests/workflow_jobs.py).
    return workflow_jobs.copy_job(job, {"steps": steps})


def holds_release_material(job: dict) -> bool:
    """Rule 6's scope: the job reads a release secret (any form workflow_jobs reads) or runs in a release
    environment."""
    # Environment names through workflow_jobs (casefolded, matrix and literal branches read); one nothing resolves
    # might be a release environment, so it counts.
    environments, unresolved = workflow_jobs.environment_values(job)
    return (release_secret(job) or any(RELEASE_ENVIRONMENT.fullmatch(name) for name in environments)
            or bool(unresolved))


def bundle_code_with_secrets(name: str, job: dict) -> list[str]:
    """Rule 6 for one job (its moved step scripts already inline): each step that runs bundle code, or a
    notarization script with its launch smokes on, in a job that holds release material."""
    if not holds_release_material(job):
        return []
    failures = []
    for step in job.get("steps") or []:
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
    return failures


# The one invocation detector lives in tests/shell_invocations.py (quoting, operators, heredocs); its cases run in
# real bash in tests/test_shell_invocations.py.


def invoked_programs(step: dict) -> list[str]:
    """The programs one step's `run:` certainly runs (must_run()): a command inside a substitution, behind an eval,
    a function or an unlexable tail is not credited, so the guards refuse a step that only maybe runs a script."""
    return [words[0] for words in must_run(str(step.get("run", "")))]


def _certificate_steps(job: dict) -> list[dict]:
    return [step for step in job.get("steps") or []
            if isinstance(step, dict) and workflow_jobs.reads_secret(step, "APPLE_CERTIFICATE_BASE64")]


def script_made_keychain(job: dict) -> str | None:
    """The KEYCHAIN_MAKING_SCRIPTS script that a step reading the Developer ID certificate runs (its moved step
    scripts already inline), if any. Only a command of that step's `run:` that invokes the script counts
    (must_run()): a step name, a comment, an env value, an echo, a heredoc body or another step that only
    mentions it makes no keychain."""
    for step in _certificate_steps(job):
        for program in invoked_programs(step):
            if program in KEYCHAIN_MAKING_SCRIPTS:
                return program
        # The script imports the certificate and makes the keychain in one: a run that skips it (a loop over
        # candidates, an if branch) imports nothing, so any run of it that bash gets to counts (run_when_reached()).
        for words in run_when_reached(str(step.get("run", ""))):
            if words[0] in KEYCHAIN_MAKING_SCRIPTS:
                return words[0]
    return None


def release_pool_signer(job: dict) -> str | None:
    """Rule 8: the release-signer script the job hands the Developer ID certificate to, read from the step that
    reads APPLE_CERTIFICATE_BASE64 (any form) and invokes it (must_run()); None when no such step runs one. A
    comment, echo, printf, quoted string or heredoc body that only names the script is no signer."""
    found = {program for step in _certificate_steps(job) for program in invoked_programs(step)
             if RELEASE_SIGNER_SCRIPT.fullmatch(program)}
    return min(found) if found else None


def makes_managed_keychain(job: dict) -> bool:
    """Rule 3: some step runs `scripts/ci/signing-keychain.sh create` (must_run()), not only names it."""
    return any(words[0] == "scripts/ci/signing-keychain.sh" and words[1:2] == ["create"]
               for step in job.get("steps") or [] if isinstance(step, dict)
               for words in must_run(str(step.get("run", ""))))


def inline_keychain(job: dict) -> bool:
    """INLINE_DEVELOPER_ID_KEYCHAINS' trait: the job reads the Developer ID certificate and imports it inline
    (`security import`), outside the release signer."""
    return (workflow_jobs.reads_secret(job, "APPLE_CERTIFICATE_BASE64") and "security import" in json.dumps(job)
            and release_pool_signer(job) is None)


def _every_job(documents: dict[str, dict]) -> Iterator[tuple[str, dict]]:
    for workflow, document in documents.items():
        for job_name, job in ((document or {}).get("jobs") or {}).items():
            if isinstance(job, dict):
                yield f"{workflow} {job_name}", inline_step_scripts(job)


def step_level_classification(documents: dict[str, dict], listed: set[str] | None = None) -> list[str]:
    """STEP_LEVEL_ONLY against the workflows: every job rule 6 names is listed (rule 6's own failures otherwise),
    and every entry is a job that rule 6 would name (else the waiver is stale)."""
    listed = STEP_LEVEL_ONLY if listed is None else listed
    failures, seen = [], set()
    for name, job in _every_job(documents):
        found = bundle_code_with_secrets(name, job)
        if name in listed:
            seen.add(name)
            if not found:
                failures.append(f"{name}: in STEP_LEVEL_ONLY but runs no bundle code while it holds release "
                                "material; drop it")
        else:
            failures.extend(found)
    failures.extend(f"{name}: in STEP_LEVEL_ONLY, but no such job" for name in sorted(set(listed) - seen))
    return failures


def inline_keychain_classification(documents: dict[str, dict], listed: set | None = None) -> list[str]:
    """INLINE_DEVELOPER_ID_KEYCHAINS against the workflows: every job with the trait (inline_keychain()) is listed,
    and every entry has it."""
    listed = INLINE_DEVELOPER_ID_KEYCHAINS if listed is None else listed
    names = {f"{workflow} {job_name}" for workflow, job_name in listed}
    failures, seen = [], set()
    for name, job in _every_job(documents):
        trait = inline_keychain(job)
        if name in names:
            seen.add(name)
            if not trait:
                failures.append(f"{name}: in INLINE_DEVELOPER_ID_KEYCHAINS but imports no Developer ID certificate "
                                "inline; drop it")
        elif trait:
            failures.append(f"{name}: imports the Developer ID certificate inline (security import) but is not in "
                            "INLINE_DEVELOPER_ID_KEYCHAINS; use scripts/ci/signing-keychain.sh create")
    failures.extend(f"{name}: in INLINE_DEVELOPER_ID_KEYCHAINS, but no such job" for name in sorted(names - seen))
    return failures


def tree_job_failures(documents: dict[str, dict], name: str) -> list[str]:
    """What check_job says about one job ("<workflow> <job>") of a fixture tree."""
    workflow, job_name = name.split(" ", 1)
    failures: list[str] = []
    check_job(name, documents[workflow]["jobs"][job_name], failures)
    return failures


# A step that reads the Developer ID certificate by bracket, as the derived-list fixtures add it.
CERTIFICATE_STEP = {"name": "Sign", "env": {"CERT": "${{ secrets['APPLE_CERTIFICATE_BASE64'] }}"}}


def step_level_fixture_failures(documents: dict[str, dict]) -> list[str]:
    """STEP_LEVEL_ONLY (a waiver, guarded): a copy of a listed job under a new id."""
    problems = []
    workflow, job_name = sorted(STEP_LEVEL_ONLY)[0].split(" ", 1)
    base = workflow_jobs.copy_job(bracketed(documents[workflow]["jobs"][job_name]), {"environment": workflow_jobs.DROP})
    fixture = with_job(documents, workflow, "step-level-fixture", base)
    label = f"{workflow} step-level-fixture"
    found = [why for why in step_level_classification(fixture) if why.startswith(label + ":")]
    if not found or not all("in a job that holds secrets" in why or "launches the app" in why for why in found):
        problems.append(f"STEP_LEVEL_ONLY: an unlisted job that runs bundle code while it holds release material "
                        f"is not named by rule 6: {found}")
    found = step_level_classification(fixture, STEP_LEVEL_ONLY | {label})
    if found:
        problems.append(f"STEP_LEVEL_ONLY: a listed job that runs bundle code with secrets fails the guard: {found}")
    quiet = with_job(documents, workflow, "step-level-fixture", {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]})
    found = step_level_classification(quiet, STEP_LEVEL_ONLY | {label})
    if found != [f"{label}: in STEP_LEVEL_ONLY but runs no bundle code while it holds release material; drop it"]:
        problems.append(f"STEP_LEVEL_ONLY: a stale entry is not named: {found}")
    return problems


def inline_keychain_fixture_failures(documents: dict[str, dict]) -> list[str]:
    """INLINE_DEVELOPER_ID_KEYCHAINS (an exemption, guarded): a copy of the listed job under a new id."""
    problems = []
    if not INLINE_DEVELOPER_ID_KEYCHAINS:
        return problems
    workflow, job_name = sorted(INLINE_DEVELOPER_ID_KEYCHAINS)[0]
    base = workflow_jobs.copy_job(bracketed(documents[workflow]["jobs"][job_name]), {"environment": workflow_jobs.DROP})
    fixture = with_job(documents, workflow, "inline-keychain-fixture", base)
    label = f"{workflow} inline-keychain-fixture"
    found = inline_keychain_classification(fixture)
    if found != [f"{label}: imports the Developer ID certificate inline (security import) but is not in "
                 "INLINE_DEVELOPER_ID_KEYCHAINS; use scripts/ci/signing-keychain.sh create"]:
        problems.append(f"INLINE_DEVELOPER_ID_KEYCHAINS: an unlisted inline import is not named: {found}")
    found = inline_keychain_classification(fixture, INLINE_DEVELOPER_ID_KEYCHAINS | {(workflow, "inline-keychain-fixture")})
    if found:
        problems.append(f"INLINE_DEVELOPER_ID_KEYCHAINS: a listed inline import fails the guard: {found}")
    quiet = with_job(documents, workflow, "inline-keychain-fixture", {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]})
    found = inline_keychain_classification(quiet, INLINE_DEVELOPER_ID_KEYCHAINS | {(workflow, "inline-keychain-fixture")})
    if found != [f"{label}: in INLINE_DEVELOPER_ID_KEYCHAINS but imports no Developer ID certificate inline; drop it"]:
        problems.append(f"INLINE_DEVELOPER_ID_KEYCHAINS: a stale entry is not named: {found}")
    return problems


def script_made_fixture_failures(documents: dict[str, dict]) -> list[str]:
    """Script-made keychains (derived): a job that hands the certificate to a keychain-making script passes rule 3 without being listed; the same job with the script call dropped is named."""
    problems = []
    made = {"runs-on": "blacksmith-6vcpu-macos-26", "steps": [{**CERTIFICATE_STEP, "run": f"./{KEYCHAIN_MAKING_SCRIPTS[0]}"}]}
    label = "release.yml script-keychain-fixture"
    found = tree_job_failures(with_job(documents, "release.yml", "script-keychain-fixture", made), label)
    found = [why for why in found if "Developer ID certificate" in why or "imports a certificate" in why]
    if found:
        problems.append(f"script-made keychains: a job whose keychain {KEYCHAIN_MAKING_SCRIPTS[0]} makes fails "
                        f"rule 3: {found}")
    bare = {"runs-on": "blacksmith-6vcpu-macos-26", "steps": [{**CERTIFICATE_STEP, "run": "./sign.sh"}]}
    found = [why for why in tree_job_failures(with_job(documents, "release.yml", "script-keychain-fixture", bare), label)
             if "Developer ID certificate" in why]
    if found != [f"{label}: imports the Developer ID certificate without scripts/ci/signing-keychain.sh create"]:
        problems.append(f"script-made keychains: a job that reads the certificate and makes no keychain is not "
                        f"named: {found}")
    # #40784: a run of the script bash may skip (a loop over candidates, an if branch) still makes the keychain
    # whenever it imports the certificate, so it is credited; a run in a substitution or behind eval is not.
    for form, run in (("in a loop", f"for c in $LIST; do ./{KEYCHAIN_MAKING_SCRIPTS[0]} \"$c\"; done"),
                      ("in an if branch", f"if [ -n \"$X\" ]; then ./{KEYCHAIN_MAKING_SCRIPTS[0]}; fi")):
        looped = {"runs-on": "blacksmith-6vcpu-macos-26", "steps": [{**CERTIFICATE_STEP, "run": run}]}
        found = [why for why in tree_job_failures(with_job(documents, "release.yml", "script-keychain-fixture", looped),
                                                  label) if "Developer ID certificate" in why]
        if found:
            problems.append(f"script-made keychains: a job that runs {KEYCHAIN_MAKING_SCRIPTS[0]} {form} fails "
                            f"rule 3: {found}")
    # Codex: the script named only as text (a step name, a comment, an env value, an echo, another step) makes no
    # keychain; the certificate step runs ./sign.sh, so rule 3 still names the job.
    script = KEYCHAIN_MAKING_SCRIPTS[0]
    for form, steps in (
            ("step name", [{**CERTIFICATE_STEP, "name": f"Sign (see {script})", "run": "./sign.sh"}]),
            ("comment", [{**CERTIFICATE_STEP, "run": f"# later: ./{script}\n./sign.sh"}]),
            ("env value", [{**CERTIFICATE_STEP, "env": {**CERTIFICATE_STEP["env"], "NEXT": script}, "run": "./sign.sh"}]),
            ("echoed", [{**CERTIFICATE_STEP, "run": f"echo ./{script}\n./sign.sh"}]),
            ("printf", [{**CERTIFICATE_STEP, "run": f"printf '%s\\n' ./{script}\n./sign.sh"}]),
            ("heredoc body", [{**CERTIFICATE_STEP, "run": f"cat <<'EOF' > next.txt\n./{script}\nEOF\n./sign.sh"}]),
            # Codex: `cat <<A <<B` opens two heredocs; B's body is text too, not a command that runs.
            ("second heredoc body", [{**CERTIFICATE_STEP, "run": f"cat <<A <<'B' > next.txt\nfirst\nA\n./{script}\nB\n./sign.sh"}]),
            # hq#9150: a quoted `;` is an argument, not a command break, so the script after it is still text.
            ("quoted semicolon", [{**CERTIFICATE_STEP, "run": f"echo \";\" ./{script}\n./sign.sh"}]),
            ("argument after a substitution", [{**CERTIFICATE_STEP, "run": f"echo $(true) ./{script}\n./sign.sh"}]),
            ("argument after backticks", [{**CERTIFICATE_STEP, "run": f"echo `true` ./{script}\n./sign.sh"}]),
            ("run inside a substitution", [{**CERTIFICATE_STEP, "run": f"x=$(./{script})\n./sign.sh"}]),
            ("run by eval", [{**CERTIFICATE_STEP, "run": f"eval ./{script}\n./sign.sh"}]),
            ("trailing comment", [{**CERTIFICATE_STEP, "run": f"./sign.sh # then ./{script}"}]),
            ("another step", [{**CERTIFICATE_STEP, "run": "./sign.sh"}, {"name": "Notarize", "run": f"./{script}"}])):
        mentioned = {"runs-on": "blacksmith-6vcpu-macos-26", "steps": steps}
        found = [why for why in tree_job_failures(with_job(documents, "release.yml", "script-keychain-fixture",
                                                           mentioned), label) if "Developer ID certificate" in why]
        if found != [f"{label}: imports the Developer ID certificate without scripts/ci/signing-keychain.sh create"]:
            problems.append(f"script-made keychains: a job that only mentions {script} ({form}) is not named: {found}")
    return problems


def release_pool_signer_fixture_failures(documents: dict[str, dict]) -> list[str]:
    """Release-pool signers (derived): a job whose certificate step runs a release-signer script is held to rule 8 without being listed; one that also makes a keychain is named."""
    problems = []
    signer = "scripts/ci/release-signer/sign-app.sh"
    good = {"runs-on": "ubuntu-24.04", "steps": [{**CERTIFICATE_STEP, "run": f"./{signer} app"}]}
    label = "nightly.yml signer-fixture"
    found = [why for why in tree_job_failures(with_job(documents, "nightly.yml", "signer-fixture", good), label)
             if "release-pool signer" in why or "Developer ID certificate" in why]
    if release_pool_signer(good) != signer or found:
        problems.append(f"release-pool signers: a signer job that keeps to rule 8 is not read as one or fails: {found}")
    keychained = {**good, "steps": [{"run": "./scripts/ci/signing-keychain.sh create"}, *good["steps"],
                                    {"if": "always()", "run": "./scripts/ci/signing-keychain.sh delete"}]}
    found = [why for why in tree_job_failures(with_job(documents, "nightly.yml", "signer-fixture", keychained), label)
             if "release-pool signer" in why]
    if found != [f"{label}: a release-pool signer runs on a literal ubuntu label, calls {signer} and makes no keychain"]:
        problems.append(f"release-pool signers: a signer job that makes a keychain is not named: {found}")
    # A real invocation behind a condition, an env assignment and a shell's options is still read as one.
    for form, run in (("if ! VAR=1", f"if ! CMUX_X=1 ./{signer} app; then exit 1; fi"),
                      ("bash -e", f"bash -e {signer} app"),
                      ("left of ||", f"./{signer} app || true"),
                      ("after a guard line", f"test -n \"$CERT\" || exit 1\n./{signer} app")):
        prefixed = {**good, "steps": [{**CERTIFICATE_STEP, "run": run}]}
        found = [why for why in tree_job_failures(with_job(documents, "nightly.yml", "signer-fixture", prefixed), label)
                 if "release-pool signer" in why or "Developer ID certificate" in why]
        if release_pool_signer(prefixed) != signer or found:
            problems.append(f"release-pool signers: a real invocation ({form}) is not read as one or fails: {found}")
    return problems


def release_pool_signer_mention_fixture_failures(documents: dict[str, dict]) -> list[str]:
    """Codex (#40846 F2): the certificate step only names a release-signer script as text (a comment, an echo, a
    printf, a heredoc body) and runs ./sign.sh, so it signs with no managed keychain; rule 3 must name it."""
    problems = []
    signer = "scripts/ci/release-signer/sign-app.sh"
    label = "nightly.yml signer-fixture"
    for form, run in (("comment", f"# {signer}\n./sign.sh"),
                      ("trailing comment", f"./sign.sh # {signer}"),
                      ("echo", f"echo ./{signer} app\n./sign.sh"),
                      ("printf", f"printf '%s\\n' ./{signer}\n./sign.sh"),
                      ("quoted string", f"./sign.sh --note \"./{signer}\""),
                      ("heredoc body", f"cat <<'EOF' > plan.txt\n./{signer} app\nEOF\n./sign.sh"),
                      # Codex (#40846 F2): a substitution makes the rest of the simple command an argument; and a
                      # signer the detector cannot be sure of (inside a substitution, behind eval or `bash -c`) is
                      # not credited, so the step is refused rather than passed with no keychain.
                      ("argument after a substitution", f"echo $(true) ./{signer}\n./sign.sh"),
                      ("argument after a nested substitution", f"echo $(echo $(true)) ./{signer}\n./sign.sh"),
                      ("argument after backticks", f"echo `true` ./{signer}\n./sign.sh"),
                      ("argument after a process substitution", f"cat <(true) ./{signer}\n./sign.sh"),
                      ("run inside a substitution", f"x=$(./{signer} app)\n./sign.sh"),
                      ("run by eval", f"eval ./{signer} app\n./sign.sh"),
                      ("run by bash -c", f"bash -c './{signer} app'\n./sign.sh"),
                      ("defined as a function", f"{signer.split('/')[-1].split('.')[0]}() {{ true; }}\n./{signer} app\n./sign.sh"),
                      # Codex (#40784 F1, BLOCK at 341c7c1b): a signer bash may skip is not credited either, so the
                      # job cannot take rule 8's no-keychain path while the signer never runs.
                      ("right of &&", f"false && ./{signer} app\n./sign.sh"),
                      ("after && on a test", f"test -n \"$CERT\" && ./{signer} app\n./sign.sh"),
                      ("in an if branch", f"if false; then ./{signer} app; fi\n./sign.sh"),
                      ("in an else branch", f"if ./sign.sh; then true; else ./{signer} app; fi"),
                      ("in a case branch", f"case \"$MODE\" in release) ./{signer} app;; esac\n./sign.sh"),
                      ("in a loop body", f"for app in; do ./{signer} \"$app\"; done\n./sign.sh"),
                      ("after exit", f"./sign.sh\nexit 0\n./{signer} app")):
        job = {"runs-on": "ubuntu-24.04", "steps": [{**CERTIFICATE_STEP, "run": run}]}
        found = [why for why in tree_job_failures(with_job(documents, "nightly.yml", "signer-fixture", job), label)
                 if "Developer ID certificate" in why or "release-pool signer" in why]
        if release_pool_signer(job) is not None or found != [
                f"{label}: imports the Developer ID certificate without scripts/ci/signing-keychain.sh create"]:
            problems.append(f"release-pool signers: a job that only mentions {signer} ({form}) is read as a signer "
                            f"or not named: {found}")
    return problems


def managed_keychain_mention_fixture_failures(documents: dict[str, dict]) -> list[str]:
    """Rule 3's managed keychain: `signing-keychain.sh create` only named as text (a comment, an echo, a heredoc body)
    makes no keychain, so a job that reads the certificate and runs ./sign.sh is named; a real create is not."""
    problems = []
    label = "release.yml managed-keychain-fixture"
    create = "./scripts/ci/signing-keychain.sh create"
    delete = {"if": "always()", "run": "./scripts/ci/signing-keychain.sh delete"}
    for form, run, named in (("real create", create, False),
                             ("real create, left of ||", f"{create} || exit 1", False),
                             # #40784 F1: a create bash may skip makes no keychain.
                             ("right of &&", f"false && {create}", True),
                             ("in an if branch", f"if false; then {create}; fi", True),
                             ("comment", f"# {create}", True),
                             ("echo", f"echo {create}", True),
                             ("heredoc body", f"cat <<EOF > plan.txt\n{create}\nEOF", True)):
        job = {"runs-on": "blacksmith-6vcpu-macos-26",
               "steps": [{"name": "Keychain", "run": run}, {**CERTIFICATE_STEP, "run": "./sign.sh"}, delete]}
        found = [why for why in tree_job_failures(with_job(documents, "release.yml", "managed-keychain-fixture", job),
                                                  label) if "Developer ID certificate" in why]
        expected = [f"{label}: imports the Developer ID certificate without scripts/ci/signing-keychain.sh create"]
        if found != (expected if named else []):
            problems.append(f"managed keychain: signing-keychain.sh create as {form} is misread: {found}")
    return problems


def keychain_cleanup_fixture_failures(documents: dict[str, dict]) -> list[str]:
    """Rule 2's cleanup (#40784 F1 sweep): an `if: always()` step counts as deleting the keychain only when bash
    surely runs the delete. `false && ./scripts/ci/signing-keychain.sh delete` or a delete in an if branch leaves the
    keychain on the runner and must be named; a delete that runs (also left of `||`) is not."""
    problems = []
    label = "release.yml cleanup-fixture"
    create = {"name": "Keychain", "run": "./scripts/ci/signing-keychain.sh create"}
    sign = {**CERTIFICATE_STEP, "run": "./sign.sh"}
    for form, run, named in (("real delete", "./scripts/ci/signing-keychain.sh delete", False),
                             ("delete || true", "./scripts/ci/signing-keychain.sh delete || true", False),
                             ("security delete-keychain", "security delete-keychain \"$K\"", False),
                             ("right of &&", "false && ./scripts/ci/signing-keychain.sh delete", True),
                             ("in an if branch", "if false; then ./scripts/ci/signing-keychain.sh delete; fi", True),
                             ("echo", "echo ./scripts/ci/signing-keychain.sh delete", True)):
        job = {"runs-on": "blacksmith-6vcpu-macos-26", "steps": [create, sign, {"if": "always()", "run": run}]}
        found = [why for why in tree_job_failures(with_job(documents, "release.yml", "cleanup-fixture", job), label)
                 if "no `if: always()` step deletes it" in why]
        expected = [f"{label}: creates a signing keychain but no `if: always()` step deletes it"]
        if found != (expected if named else []):
            problems.append(f"keychain cleanup: an always() delete as {form} is misread: {found}")
    # A keychain in a job with no signing secret holds no signing identity: an uncertain delete (under sudo) is not
    # named there, and is named once the job reads the certificate.
    sudo_delete = {"if": "always()", "run": "sudo -n -u \"$U\" -- security delete-keychain \"$K\" || true"}
    for form, steps, named in (("no signing secret", [{"run": "security create-keychain -p x \"$K\""}, sudo_delete], False),
                               ("a signing secret", [{"run": "security create-keychain -p x \"$K\""}, sign, sudo_delete],
                                True)):
        job = {"runs-on": "blacksmith-6vcpu-macos-26", "steps": steps}
        found = [why for why in tree_job_failures(with_job(documents, "release.yml", "cleanup-fixture", job), label)
                 if "no `if: always()` step deletes it" in why]
        expected = [f"{label}: creates a signing keychain but no `if: always()` step deletes it"] if named else []
        if found != expected:
            problems.append(f"keychain cleanup: a sudo delete with {form} is misread: {found}")
    return problems


def keychain_list_fixture_failures(documents: dict[str, dict]) -> list[str]:
    """The four keychain lists' fixtures, each built on every workflow document (with_job). Each red fixture adds a
    job with the list's trait that reads its secrets by bracket (`secrets['X']`) and carries no release
    environment, so only a secret reader that knows that form sees it; the guard must name it. Each green fixture
    adds a correctly listed (or, for a derived list, correctly shaped) job, and the guard must stay quiet."""
    return [*step_level_fixture_failures(documents), *inline_keychain_fixture_failures(documents),
            *script_made_fixture_failures(documents), *release_pool_signer_fixture_failures(documents),
            *release_pool_signer_mention_fixture_failures(documents),
            *managed_keychain_mention_fixture_failures(documents), *keychain_cleanup_fixture_failures(documents)]


def check_keychain_lists(documents: dict[str, dict], failures: list[str]) -> None:
    """The four keychain lists against the workflows (stale entries; unlisted jobs fail check_job) and their
    fixtures."""
    failures.extend(why for why in step_level_classification(documents) if "STEP_LEVEL_ONLY" in why)
    failures.extend(inline_keychain_classification(documents))
    if not any(script_made_keychain(job) for _, job in _every_job(documents)):
        failures.append(f"no job runs one of {KEYCHAIN_MAKING_SCRIPTS}; is this the right tree?")
    failures.extend(keychain_list_fixture_failures(documents))


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
        # A keychain is deleted only by a delete bash surely runs (must_run()); a line that names one behind `&&`, in
        # an if branch or in an echo deletes nothing (#40784 F1 sweep). Creating stays read off any mention: it
        # opens the window, which only makes the guard stricter.
        deletes = any(deletes_keychain(words) for words in must_run(str(step.get("run", ""))))
        for command in commands(str(step.get("run", ""))):
            if CREATE.search(command):
                open_window = label
                created = True
                continue
            if DELETE.search(command):
                if deletes:
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
    # Only a job that holds a signing secret can put a signing identity in the keychain it makes; a test user's
    # login keychain (machine-vault-e2e.yml, deleted under `sudo -n`, which must_run() cannot be sure of) holds none.
    if created and not cleaned_up and signing_secret(job):
        failures.append(f"{name}: creates a signing keychain but no `if: always()` step deletes it")

    if name not in STEP_LEVEL_ONLY:
        failures.extend(bundle_code_with_secrets(name, job))
    # stable-next.yml's sign keeps an owned route for its keyless dry run; test_ci_signing_owned_mac.py exempts it
    # from the whole-mini claim because its signing secrets sit behind the condition that picks Blacksmith.
    failures.extend(secret_gate_failures(name, job) or [])
    # Rule 7a: the whole-mini claim that #53754 kept ("the whole-mini signing claim stay[s]"); its call lived in the
    # deleted rule-7 runs-on loop, so it is made here for every claim-gated job that holds a signing secret.
    if signing_secret(job) and claim_gated(name, job):
        failures.extend(owned_route_failures(name, job))

    text = json.dumps(job)
    pool_signer = release_pool_signer(job)
    if pool_signer:
        # Every matrix cell's runner (workflow_jobs.runs_on_cells); a runner nothing resolves is not a literal ubuntu label.
        cells = workflow_jobs.runs_on_cells(job)
        if ("keychain" in text or pool_signer not in text or not cells
                or any("ubuntu" not in cell or "macos" in cell for cell in cells)):
            failures.append(f"{name}: a release-pool signer runs on a literal ubuntu label, calls {pool_signer} and makes no keychain")
        certificate_steps = [step for step in steps if isinstance(step, dict) and workflow_jobs.reads_secret(step, "APPLE_CERTIFICATE_BASE64")]
        if not certificate_steps or any(pool_signer not in invoked_programs(step) for step in certificate_steps):
            failures.append(f"{name}: only the step that runs {pool_signer} may hold the Developer ID certificate")
        if secret_or_token(workflow_jobs.resolve(job).env):
            failures.append(f"{name}: job-level env holds a secret or the job token; set it on the steps that use it")
    elif workflow_jobs.reads_secret(job, "APPLE_CERTIFICATE_BASE64") and name not in {
        f"{workflow} {job_name}" for workflow, job_name in INLINE_DEVELOPER_ID_KEYCHAINS
    }:
        if not makes_managed_keychain(job) and not script_made_keychain(job):
            failures.append(f"{name}: imports the Developer ID certificate without scripts/ci/signing-keychain.sh create")
        if "security import" in text:
            failures.append(f"{name}: imports a certificate inline; use scripts/ci/signing-keychain.sh create")
        if secret_or_token(workflow_jobs.resolve(job).env):
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

    # next-pkg.sh signs only the installer package (productbuild through build-pkg.sh) and runs no bundle code: it
    # makes the keychain, signs, then deletes it, and its RETURN trap deletes it on every early return.
    pkg = read_lines("scripts/ci/nightly-next-pkg.sh", failures)
    pkg_create = index_of(pkg, '"$KEYCHAIN_TOOL" create')
    pkg_sign = index_of(pkg, '"$BUILD_PKG" ')
    pkg_delete = next((number for number, line in enumerate(pkg)
                       if number > pkg_sign >= 0 and '"$KEYCHAIN_TOOL" delete' in line
                       and not line.lstrip().startswith("#")), -1)
    pkg_trap = index_of(pkg, '[ "$keychain_made" = 1 ] && "$KEYCHAIN_TOOL" delete')
    if not (0 <= pkg_create < pkg_sign < pkg_delete) or not (0 <= pkg_trap < pkg_create):
        failures.append(
            "scripts/ci/nightly-next-pkg.sh: make the keychain, sign the package, then delete it, with the "
            f"RETURN trap deleting it on an early return (create={pkg_create} sign={pkg_sign} delete={pkg_delete} "
            f"trap={pkg_trap})"
        )

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


def check_literal_selectors(failures: list[str]) -> None:
    """A selector is dropped only when it picks the literal it compares against, and that literal is ephemeral."""
    cases = {
        "${{ vars.LINUX_RUNNER == 'blacksmith-16vcpu-ubuntu-2404' && 'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-32vcpu-ubuntu-2404' }}":
            "${{ 'blacksmith-32vcpu-ubuntu-2404' }}",
        "${{ vars.LINUX_RUNNER == 'blacksmith-16vcpu-ubuntu-2404' && 'glaeda-std-xcode-26.6' || 'blacksmith-32vcpu-ubuntu-2404' }}": None,
        "${{ vars.X == 'glaeda-std-xcode-26.6' && 'glaeda-std-xcode-26.6' || 'blacksmith-32vcpu-ubuntu-2404' }}": None,
        # The nightly's hosted switch, routed to the one-job JIT VM: dropped.
        "${{ vars.X == 'ubuntu-24.04' && 'cmux-gcp-nightly-jit-x64' || 'glaeda-trusted-next-signing' }}":
            "${{ 'glaeda-trusted-next-signing' }}",
        # A JIT label behind a persistent runner's name, or a persistent label behind an ephemeral one: kept.
        "${{ vars.X == 'glaeda-std-xcode-26.6' && 'cmux-gcp-nightly-jit-x64' || 'blacksmith-32vcpu-ubuntu-2404' }}": None,
        "${{ vars.X == 'ubuntu-24.04' && 'glaeda-std-xcode-26.6' || 'blacksmith-32vcpu-ubuntu-2404' }}": None,
        # Any other cmux-gcp label (outside JIT_EPHEMERAL_LABELS) is not admitted as ephemeral.
        "${{ vars.X == 'cmux-gcp-nightly-x64' && 'cmux-gcp-nightly-x64' || 'blacksmith-32vcpu-ubuntu-2404' }}": None,
    }
    for runs_on, expected in cases.items():
        if strip_literal_selectors(runs_on) != (runs_on if expected is None else expected):
            failures.append(f"strip_literal_selectors mishandles {runs_on}")


def main() -> int:
    failures: list[str] = []
    check_literal_selectors(failures)
    signing_jobs = 0
    documents = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = workflow_jobs.document(path)
        documents[path.name] = document
        for job_name, job in (document.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            if "keychain" in json.dumps(inline_step_scripts(job)):
                signing_jobs += 1
            check_job(f"{path.name} {job_name}", job, failures)
    check_gated_secret_classification(documents, failures)
    check_keychain_lists(documents, failures)
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
