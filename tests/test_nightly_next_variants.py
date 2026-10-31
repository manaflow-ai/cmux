#!/usr/bin/env python3
"""Every nightly-next build ships a thin arm64 and a thin x86_64 DMG together.

Two nightly-next runs in a row (37648507383, 37667249069) lost all three DMG
notarizations to Apple's queue, so nightly-next dropped to arm64 only (#18424)
and Intel Macs got no new cmux NEXT. It now builds arm64 and x86_64 (two
notarizations, no universal one), and both are required: a build publishes
both or neither, including a build a later run recovers. Main's nightly keeps
arm64, x86_64 and universal.
"""

import hashlib
import json
import os
import re
import subprocess
import tempfile
import textwrap
import sys
from pathlib import Path

from test_ci_nightly_push_throttle import NEXT_ENV, run_decide
from nightly_workflow_text import nightly_text

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
TEXT = nightly_text()
FOUR = ["appcast-arm64.xml", "appcast-x86_64.xml", "appcast-universal.xml", "appcast.xml"]


def job(name):
    start = TEXT.index(f"  {name}:\n")
    end = re.search(r"^  [a-zA-Z0-9_-]+:", TEXT[start + len(name) + 4:], re.M)
    return TEXT[start:] if end is None else TEXT[start:start + len(name) + 4 + end.start()]


def step(name):
    start = TEXT.index(f"      - name: {name}\n")
    end = TEXT.find("\n      - name:", start + 10)
    return TEXT[start:] if end < 0 else TEXT[start:end]


failures = []

decide = TEXT[TEXT.index("  decide:\n"):TEXT.index("\n  promote-nightly-next:\n")]
if "core.setOutput('feeds'" not in decide or "feeds: ${{ steps.decide.outputs.feeds }}" not in TEXT:
    failures.append("decide must output the feeds this track publishes")
if decide.index("const track =") > decide.index("const variants ="):
    failures.append("decide must choose the variants after it knows the track")

# decide, executed: variants and feeds per track.
EXPECTED = {
    ("nightly-next", False): (["arm64", "x86_64"], ["appcast-arm64.xml", "appcast-x86_64.xml"]),
    ("main", False): (["arm64", "x86_64", "universal"], FOUR),
    ("rc/v1.2.3", False): (["arm64", "x86_64", "universal"], FOUR),
    ("main", True): (["arm64"], FOUR),
}
for (ref, fast), (variants, feeds) in EXPECTED.items():
    outputs = run_decide(event="workflow_dispatch", ref=f"refs/heads/{ref}",
                         extra_env={**NEXT_ENV, "FAST_BUILD": str(fast).lower()})["outputs"]
    got = (json.loads(outputs["variants"]), outputs["feeds"].split())
    if got != (variants, feeds):
        failures.append(f"decide {ref} fast={fast}: got {got}, expected {(variants, feeds)}")

# Both legs are required: no matrix job lets a leg fail alone.
for name in ("prepare-nightly-variant", "build-sign-notarize-nightly", "verify-signed-nightly",
             "verify-final-dmg-nightly"):
    if "continue-on-error" in job(name).split("    steps:", 1)[0]:
        failures.append(f"{name} must not let a variant's leg fail alone")
# Only arm64 hands a slow notarization to a later run, and only it sets the hand-off outputs.
if "notary_pending: ${{ (needs.decide.outputs.track != 'nightly-next' || matrix.variant == 'arm64') &&" not in TEXT:
    failures.append("notary_pending must come from the arm64 leg on nightly-next")
if "needs.decide.outputs.no_publish != 'true' && matrix.variant == 'arm64' && 'true' || 'false' }}" not in TEXT:
    failures.append("only the arm64 leg may hand a pending notarization to the recovery")
# The x86_64 final DMG is smoked even while arm64 is pending, for the recovery to take.
if "(matrix.variant != 'arm64' || needs.build-sign-notarize-nightly.outputs.notary_pending != 'true')" not in job("verify-final-dmg-nightly"):
    failures.append("verify-final-dmg-nightly must smoke x86_64 while arm64 is pending")

# A failed notarize leg on nightly-next may be recovered later: both verify
# jobs still run, so that run's x86_64 is verified for the recovery.
for name in ("verify-signed-nightly", "verify-final-dmg-nightly"):
    if "needs.decide.outputs.track == 'nightly-next' && needs.build-sign-notarize-nightly.result == 'failure'" not in job(name).split("    steps:", 1)[0]:
        failures.append(f"{name} must run its legs after a failed nightly-next notarize job")

# A canary pass promotes the build from Dev to Nightly on both architectures'
# feeds: an Intel item left on Dev would never reach a Mac on the Nightly ring.
VERDICT = (ROOT / ".github" / "workflows" / "nightly-next-verdict.yml").read_text()
promote = VERDICT[VERDICT.index("      - name: Move builds whose canary passed to Nightly\n"):]
promote = promote[:promote.index("\n      - name:", 10)]
if "NIGHTLY_APPCASTS: appcast-arm64.xml appcast-x86_64.xml" not in VERDICT or "for appcast in $NIGHTLY_APPCASTS" not in promote:
    failures.append("nightly-next-verdict.yml must promote appcast-arm64.xml and appcast-x86_64.xml")

# A rollback pulls the bad build off the Intel feed too, in a job of its own
# that follows the build appcast-arm64.xml now serves and never holds the fix-forward.
ROLLBACK = (ROOT / ".github" / "workflows" / "nightly-next-rollback.yml").read_text()
intel = ROLLBACK[ROLLBACK.index("  rollback-intel:\n"):ROLLBACK.index("  fix-forward:\n")] if "  rollback-intel:\n" in ROLLBACK else ""
if ("INTEL_APPCAST: appcast-x86_64.xml" not in intel or '--above "$SERVING"' not in intel
        or "needs.rollback.outputs.serving" not in intel or "rollback-intel" in ROLLBACK[ROLLBACK.index("  fix-forward:\n"):]):
    failures.append("nightly-next-rollback.yml must pull the bad build off appcast-x86_64.xml in rollback-intel, without holding fix-forward")

# publish: nightly-next publishes both aliases and both feeds, and refuses a missing variant.
publish = step("Publish nightly release assets")
if 'variants=(arm64 x86_64)' not in publish or "$NIGHTLY_FEEDS" not in publish:
    failures.append("'Publish nightly release assets' must publish arm64 and x86_64 on nightly-next")
for name in ("Guard nightly-next publication", "Upload nightly-next appcasts to R2", "Upload nightly appcasts to R2"):
    body = step(name)
    if "appcast-x86_64.xml" in body or "$NIGHTLY_FEEDS" not in body:
        failures.append(f"{name!r} must loop over $NIGHTLY_FEEDS, not a fixed list")
assemble = step("Assemble legacy nightly names")
if "for variant in arm64 x86_64" not in assemble:
    failures.append("'Assemble legacy nightly names' must require both thin variants on nightly-next")
notes = step("Prepare nightly release notes and appcast summaries")
if "--feeds" not in notes or "$NIGHTLY_FEEDS" not in notes or "${intel_line}" not in notes.split("else", 1)[0]:
    failures.append("the nightly-next release notes must list the Intel download")
for name in ("Publish verified nightly release metadata", "Record verified nightly publication"):
    if "x86_64.dmg" in step(name):
        failures.append(f"{name!r} must take its download list from the notes step, which knows the track")


def run_script(body, env_extra, files):
    script = textwrap.dedent(body.split("        run: |\n", 1)[1])
    with tempfile.TemporaryDirectory(prefix="nightly-variants-") as directory:
        root = Path(directory)
        for name, text in files.items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(text)
        env = {"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", **env_extra}
        return subprocess.run(["/bin/bash", "-c", script], cwd=root, env=env, capture_output=True, text=True).returncode


require = step("Require every variant")
both = {"nightly-out/p-arm64-123.dmg": "x", "nightly-out/p-x86_64-123.dmg": "x"}
env = {"VARIANTS": json.dumps(["arm64", "x86_64"]), "CHANNEL_DMG_PREFIX": "p", "NIGHTLY_BUILD": "123"}
if run_script(require, env, both) != 0:
    failures.append("'Require every variant' must pass with arm64 and x86_64")
if run_script(require, env, {"nightly-out/p-arm64-123.dmg": "x"}) == 0:
    failures.append("'Require every variant' must refuse an Apple silicon build without its Intel build")

# nightly-next goes live from R2 and copies to the GitHub release after: every
# step on that path takes each architecture's DMG, named by its own feed.
STUB = 'import json, os, sys\nopen(os.environ["LOG"], "a").write(json.dumps(sys.argv[1:]) + "\\n")\n'
next_files = {
    **both,
    "pub/ci/publish-nightly-next-r2.py": STUB,
    "pub/ci/publish-release-assets.py": STUB,
    "next-github/appcast-arm64.xml": "a",
    "next-github/appcast-x86_64.xml": "x",
}
next_env = {"NIGHTLY_FEEDS": "appcast-arm64.xml appcast-x86_64.xml", "CHANNEL_DMG_PREFIX": "p",
            "NIGHTLY_BUILD": "123", "CHANNEL_RELEASE_TAG": "nightly-next", "GITHUB_REPOSITORY": "o/r"}


def run_logged(name, files, extra=None):
    with tempfile.TemporaryDirectory(prefix="nightly-next-log-") as directory:
        log = Path(directory) / "log"
        log.touch()
        out = Path(directory) / "out"
        runner = Path(directory) / "runner"
        runner.mkdir()
        (runner / "still-newest").write_text("#!/bin/sh\nexit 0\n")
        (runner / "still-newest").chmod(0o755)
        env = {**next_env, "LOG": str(log), "GITHUB_OUTPUT": str(out), "RUNNER_TEMP": str(runner), **(extra or {})}
        code = run_script(step(name), env, files)
        return code, [json.loads(line) for line in log.read_text().splitlines()]


# run_script runs in a fresh directory: PUBLISH_TOOLING ("pub") is relative to it.
TOOLING = {"PUBLISH_TOOLING": "pub"}
code, calls = run_logged("Publish the nightly-next download to R2", next_files, TOOLING)
uploads = [call[call.index("--file") + 1] for call in calls if call[0] == "upload"]
rewrites = [(call[call.index("--feed") + 1], call[call.index("--name") + 1]) for call in calls if call[0] == "rewrite"]
if code != 0 or uploads != ["nightly-out/p-arm64-123.dmg", "nightly-out/p-x86_64-123.dmg"] or rewrites != [
        ("nightly-out/appcast-arm64.xml", "p-arm64-123.dmg"), ("nightly-out/appcast-x86_64.xml", "p-x86_64-123.dmg")]:
    failures.append(f"the R2 download step must upload each variant's DMG and name it in its own feed: {code} {calls}")

digests = "".join(f"{hashlib.sha256(b'x').hexdigest()}  p-{v}-123.dmg\n" for v in ("arm64", "x86_64"))
code, _ = run_logged("Require the DMG to match a tested digest", {**next_files, "tested/t.sha256": digests})
if code != 0:
    failures.append("the GitHub release job must accept both tested DMGs")
code, _ = run_logged("Require the DMG to match a tested digest", {**next_files, "tested/t.sha256": digests.splitlines()[0] + "\n"})
if code == 0:
    failures.append("the GitHub release job must refuse an Intel DMG with no tested digest")

code, calls = run_logged("Publish nightly-next release assets", next_files, TOOLING)
if code != 0 or not calls or not {"nightly-out/p-arm64-123.dmg", "nightly-out/p-x86_64-123.dmg"} <= set(calls[0]):
    failures.append(f"the GitHub release job must upload both versioned DMGs: {code} {calls}")

code, calls = run_logged("Publish the rolling DMG name and the feed copy", next_files, TOOLING)
aliases = [call[i + 1] for call in calls for i, arg in enumerate(call) if arg == "--alias"]
if code != 0 or aliases != ["nightly-out/p-arm64.dmg", "nightly-out/p-x86_64.dmg"]:
    failures.append(f"the release's rolling names must cover both architectures: {code} {calls}")

if '--name "$RELEASE_NAME $NIGHTLY_BUILD"' not in step("Record the published build in the release body"):
    failures.append("the nightly-next release title must carry the build number")

# A recovered arm64 build ships only with its own run's verified x86_64 leg.
recover = job("recover-nightly-next-notarization")
cont = recover[recover.index("      - name: Continue the newest accepted pending notarization\n"):]
for needle in ("cmux-nightly-variant-x86_64", "cmux-nightly-tested-x86_64", "cmux-nightly-signed-verified-x86_64",
               "cmux-nightly-signed-verified-arm64", "has no verified Intel (x86_64) app or arm64 signed app; skipping"):
    if needle not in cont:
        failures.append(f"the recovery must check the candidate's x86_64 leg ({needle})")
if cont.index("has no verified Intel (x86_64) app") > cont.index("./scripts/ci/notarize-nightly-dmg.sh"):
    failures.append("the recovery must check x86_64 before any notarization step")
for name in ("cmux-nightly-recovered-variant-x86_64", "cmux-nightly-recovered-tested-x86_64"):
    if f"name: {name}" not in recover:
        failures.append(f"the recovery must upload {name} for publish-nightly")
if "cmux-nightly-signed-verified-${{ matrix.variant }}" not in job("verify-signed-nightly"):
    failures.append("verify-signed-nightly must record each verified variant for the recovery")

# The resolved cmux-tui publication includes a checksum-verified acpmux
# companion. Fetch it before the app job's acpmux step so the existing
# commit-addressed helper cache can reuse it instead of starting Cargo.
app_job = job("build-nightly-app")
try:
    tree_fetch_at = app_job.index("      - name: Fetch the resolved cmux-tui tree companions\n")
except ValueError:
    tree_fetch_at = -1
try:
    acpmux_at = app_job.index("      - name: Build in-tree acpmux for the compilation cache\n")
except ValueError:
    acpmux_at = -1
if tree_fetch_at < 0:
    failures.append("build-nightly-app must fetch resolved cmux-tui tree companions")
elif acpmux_at < 0 or tree_fetch_at > acpmux_at:
    failures.append("resolved cmux-tui tree companions must be fetched before the acpmux cache step")
else:
    fetch_end = app_job.find("\n      - name:", tree_fetch_at + 10)
    fetch_step = app_job[tree_fetch_at:fetch_end if fetch_end >= 0 else None]
    if (
        "pin-cmux-tui.sh fetch" not in fetch_step
        or "CMUX_TUI_TREE_KEY" not in fetch_step
        or "CMUX_TUI_TREE_TARGET: aarch64-apple-darwin" not in fetch_step
        or "pin-cmux-tui.sh acpmux-path" not in fetch_step
        or "CMUX_NEXT_ACPMUX_BIN=$acpmux_bin" not in fetch_step
        or "needs.decide.outputs.fast_build != 'true'" not in fetch_step
        or "needs.decide.outputs.build_only != 'true'" not in fetch_step
        or "inputs.nightly_next_unsigned_run == ''" not in fetch_step
    ):
        failures.append("resolved tree companion fetch must hand its verified acpmux path to the app build")

build_step = app_job[acpmux_at:]
if "Reusing the attested same-tree acpmux companion" not in build_step or "CMUX_NEXT_ACPMUX_BIN:-" not in build_step:
    failures.append("acpmux build step must reuse a verified companion before its Cargo fallback")


def build_env(body, outputs):
    values = {}
    for key, value in re.findall(r"^ +([A-Z_]+): (.+)$", body, re.M):
        if key not in ("NIGHTLY_FAST_BUILD", "NIGHTLY_COMPILE_ARCHS", "CMUX_NEXT_ACPMUX_ARCHS"):
            continue
        value = value.strip('"')
        match = re.fullmatch(r"\$\{\{ needs\.decide\.outputs\.([a-z_]+) \}\}", value)
        values[key] = str(outputs.get(match[1], "")) if match else value
    return values


def compile_commands(outputs):
    """Run the actual helper and app build steps with recorder executables, never compilers."""
    with tempfile.TemporaryDirectory(prefix="nightly-compile-archs-") as directory:
        root = Path(directory)
        stubs = {
            # The recorder invokes the workflow snippets without running a
            # compiler.  Keep any nightly_build_state.py call a no-op,
            # while still forwarding the helper's `python3 -- command`
            # shape to the command recorder.
            "bin/python3": 'case "${1:-}" in scripts/ci/nightly_build_state.py) exit 0;; scripts/ci/run-with-helper-prebuild.py) script="$1"; shift; exec "$script" "$@";; --) shift; exec "$@";; *) exec /usr/bin/python3 "$@";; esac',
            "bin/xcodebuild": 'printf "%s\\n" "$@" > "$CAPTURE/app"',
            "bin/lipo": 'exit 0',
            "bin/rustup": 'exit 0',
            "scripts/ci/run-xcodebuild-with-diagnostics.sh": 'shift; exec "$@"',
            "scripts/ci/run-with-helper-prebuild.py": 'while [ "${1:-}" != -- ]; do shift; done; shift; exec "$@"',
            "scripts/cmux-next/build-acpmux.sh": 'printf "%s" "$CMUX_NEXT_ACPMUX_ARCHS" > "$CAPTURE/acpmux"',
            "scripts/cmux-next/build-optchat-chief.sh": 'printf "%s" "$CMUX_NEXT_OPTCHAT_CHIEF_ARCHS" > "$CAPTURE/chief"',
            "scripts/cmux-next/build-mobile-host.sh": 'printf "%s" "$CMUX_NEXT_MOBILE_HOST_ARCHS" > "$CAPTURE/mobile"',
            "scripts/build-ghostty-cli-helper.sh": 'printf "%s\\n" "$@" > "$CAPTURE/ghostty"',
        }
        for path, body in stubs.items():
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
            target.chmod(0o755)
        # The Chief step installs its toolchain, then builds in the background
        # (background_build.py); the recorder joins it before reading.
        (root / "cmux-tui").mkdir()
        (root / "cmux-tui/rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.95.0"\n')
        (root / "cmux-next-ios/rust").mkdir(parents=True)
        (root / "scripts/ci/background_build.py").write_text((ROOT / "scripts/ci/background_build.py").read_text())
        (root / "scripts/lib").mkdir(parents=True)
        (root / "scripts/lib/rust-targets.sh").write_text((ROOT / "scripts/lib/rust-targets.sh").read_text())
        capture = root / "capture"
        capture.mkdir()
        steps = (
            ("build-nightly-ghostty-cli-helper", "Build Ghostty CLI helper"),
            ("build-nightly-app", "Build in-tree acpmux for the compilation cache"),
            ("build-nightly-app", "Build the OptChat Chief (cmux-next)"),
            ("build-nightly-app", "Build the cmux-next iPhone host (cmux-mobile-host)"),
            ("build-nightly-app", "Build nightly app (Release)"),
        )
        for owner, name in steps:
            body = job(owner)
            start = body.index(f"      - name: {name}\n")
            next_step = body.find("\n      - name:", start + 10)
            body_step = body[start:] if next_step < 0 else body[start:next_step]
            script = textwrap.dedent(body_step.split("        run: |\n", 1)[1])
            env = {**os.environ, **build_env(body.split("    steps:", 1)[0], outputs),
                   **build_env(body_step, outputs),
                   "PATH": str(root / "bin") + ":/usr/bin:/bin",
                   "CAPTURE": str(capture), "RUNNER_TEMP": str(root),
                   "GITHUB_ENV": str(root / "github-env"),
                   "GITHUB_STEP_SUMMARY": str(root / "step-summary"), "CHANNEL_ICON_NAME": "AppIcon-Nightly",
                   "IMPORT_VARIANT": "full", "SWIFT_IMPORT_FLAGS": "", "EMPTY_BROWSER_SOURCES": "false"}
            subprocess.run(["/bin/bash", "-c", script], cwd=root, env=env,
                           capture_output=True, text=True, check=True)
            if "background_build.py start" in script:
                subprocess.run(["/usr/bin/python3", "scripts/ci/background_build.py", "join", "--state",
                                str(root / "nightly-helper-builds"),
                                "mobile-host" if "build-mobile-host.sh" in script else "optchat-chief"],
                               cwd=root, env=env, capture_output=True, text=True, check=True)
        return {path.name: path.read_text() for path in capture.iterdir()}


# The producer compiles exactly the architectures the publish matrix needs.
# Execute its commands with recorders so this catches the actual requested
# architectures without building on a developer Mac.
for ref, fast in (("nightly-next", False), ("main", False), ("rc/v1.2.3", False), ("main", True)):
    outputs = run_decide(event="workflow_dispatch", ref=f"refs/heads/{ref}",
                         extra_env={**NEXT_ENV, "FAST_BUILD": str(fast).lower()})["outputs"]
    arm64_only = json.loads(outputs["variants"]) == ["arm64"]
    commands = compile_commands(outputs)
    expected = "arm64" if arm64_only else "arm64 x86_64"
    if f"ARCHS={expected}" not in commands["app"].splitlines():
        failures.append(f"{ref} fast={fast}: Xcode compiled an architecture the publish matrix does not need")
    for helper in ("acpmux", "chief", "mobile"):
        if commands[helper].replace(",", " ").split() != expected.split():
            failures.append(f"{ref} fast={fast}: {helper} built {commands[helper]!r}, expected {expected!r}")
    helper_args = commands["ghostty"].splitlines()
    if ("--universal" in helper_args) == arm64_only:
        failures.append(f"{ref} fast={fast}: Ghostty CLI helper does not follow the publish architectures")


if failures:
    print("FAIL: nightly-next variants\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next variants")
