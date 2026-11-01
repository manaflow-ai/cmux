#!/usr/bin/env python3
"""The nightly-next track builds, notarizes and publishes only the arm64 variant.

Two nightly-next runs in a row (37648507383, 37667249069) lost all three DMG
notarizations to Apple's queue. Leo's call: nightly-next ships arm64 only, so
each build waits on one notarization. Main's nightly keeps arm64, x86_64 and
universal, and nightly-next leaves its x86_64, universal and legacy feeds on
their last build (an Intel Mac must never be offered an arm64-only app).
"""

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


def step(name):
    start = TEXT.index(f"      - name: {name}\n")
    end = TEXT.find("\n      - name:", start + 10)
    return TEXT[start:] if end < 0 else TEXT[start:end]


failures = []

# decide: one variant and one feed on nightly-next, three and four elsewhere.
decide = TEXT[TEXT.index("  decide:\n"):TEXT.index("\n  promote-nightly-next:\n")]
variants = re.search(r"const variants = (.+);", decide)
if not variants or "nightly-next" not in variants.group(1) or "['arm64', 'x86_64', 'universal']" not in variants.group(1):
    failures.append("decide must build only ['arm64'] on the nightly-next track and keep three variants elsewhere")
if "core.setOutput('feeds'" not in decide or "feeds: ${{ steps.decide.outputs.feeds }}" not in TEXT:
    failures.append("decide must output the feeds this track publishes")
if decide.index("const track =") > decide.index("const variants ="):
    failures.append("decide must choose the variants after it knows the track")

# publish: every feed list comes from decide, so nightly-next never touches the
# x86_64, universal or legacy feeds and main's list is unchanged.
for name in ("Guard nightly-next publication", "Upload nightly-next appcasts to R2", "Upload nightly appcasts to R2"):
    body = step(name)
    if "appcast-x86_64.xml" in body or "$NIGHTLY_FEEDS" not in body:
        failures.append(f"{name!r} must loop over $NIGHTLY_FEEDS, not a fixed list")
publish = step("Publish nightly release assets")
if "nightly-next" not in publish or "x86_64" not in publish:
    failures.append("'Publish nightly release assets' must publish only arm64 on nightly-next and all variants elsewhere")
assemble = step("Assemble legacy nightly names")
if "nightly-next" not in assemble:
    failures.append("'Assemble legacy nightly names' must skip the universal legacy names on nightly-next")
notes = step("Prepare nightly release notes and appcast summaries")
if "--feeds" not in notes or "$NIGHTLY_FEEDS" not in notes:
    failures.append("the release notes step must pass --feeds $NIGHTLY_FEEDS")
for name in ("Publish verified nightly release metadata", "Record verified nightly publication"):
    if "x86_64.dmg" in step(name):
        failures.append(f"{name!r} must take its download list from the notes step, which knows the track")

def job(name):
    start = TEXT.index(f"  {name}:\n")
    end = re.search(r"^  [a-zA-Z0-9_-]+:", TEXT[start + len(name) + 4:], re.M)
    return TEXT[start:] if end is None else TEXT[start:start + len(name) + 4 + end.start()]


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
        # The Release step sources the shared cache-failure classifier (#30107).
        (root / "scripts/cmux-next/lib").mkdir(parents=True)
        (root / "scripts/cmux-next/lib/compilation-cache.sh").write_text(
            (ROOT / "scripts/cmux-next/lib/compilation-cache.sh").read_text())
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
                   "GITHUB_ENV": str(root / "github-env"), "CHANNEL_ICON_NAME": "AppIcon-Nightly",
                   "IMPORT_VARIANT": "full", "SWIFT_IMPORT_FLAGS": "", "EMPTY_BROWSER_SOURCES": "false"}
            subprocess.run(["/bin/bash", "-c", script], cwd=root, env=env,
                           capture_output=True, text=True, check=True)
            if "background_build.py start" in script:
                subprocess.run(["/usr/bin/python3", "scripts/ci/background_build.py", "join", "--state",
                                str(root / "nightly-helper-builds"),
                                "mobile-host" if "build-mobile-host.sh" in script else "optchat-chief"],
                               cwd=root, env=env, capture_output=True, text=True, check=True)
        return {path.name: path.read_text() for path in capture.iterdir()}


# The publish matrix has been arm64-only since #18424, but the producer still
# paid for both Swift whole-module compiles and universal embedded helpers.
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
    print("FAIL: nightly-next arm64 only\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next arm64 only")
