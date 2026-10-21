#!/usr/bin/env python3
"""The nightly-next track ships a thin arm64 and an optional thin x86_64 DMG.

Two nightly-next runs in a row (37648507383, 37667249069) lost all three DMG
notarizations to Apple's queue, so nightly-next dropped to arm64 only (#18424)
and Intel Macs got no new cmux NEXT. It now builds arm64 and x86_64 (two
notarizations, no universal one). x86_64 is optional: a leg that fails or is
not accepted in time never holds the arm64 publish, and its DMG names and feed
keep their last build. Main's nightly keeps arm64, x86_64 and universal.
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

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
TEXT = WORKFLOW.read_text()
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

# decide, executed: variants, optional variants and feeds per track.
EXPECTED = {
    ("nightly-next", False): (["arm64", "x86_64"], "x86_64", ["appcast-arm64.xml", "appcast-x86_64.xml"]),
    ("main", False): (["arm64", "x86_64", "universal"], "", FOUR),
    ("rc/v1.2.3", False): (["arm64", "x86_64", "universal"], "", FOUR),
    ("main", True): (["arm64"], "", FOUR),
}
for (ref, fast), (variants, optional, feeds) in EXPECTED.items():
    outputs = run_decide(event="workflow_dispatch", ref=f"refs/heads/{ref}",
                         extra_env={**NEXT_ENV, "FAST_BUILD": str(fast).lower()})["outputs"]
    got = (json.loads(outputs["variants"]), outputs.get("optional_variants"), outputs["feeds"].split())
    if got != (variants, optional, feeds):
        failures.append(f"decide {ref} fast={fast}: got {got}, expected {(variants, optional, feeds)}")

# Every matrix leg of an optional variant may fail without failing its job.
for name in ("prepare-nightly-variant", "build-sign-notarize-nightly", "verify-signed-nightly",
             "verify-final-dmg-nightly", "generate-nightly-deltas"):
    if "continue-on-error: ${{ contains(needs.decide.outputs.optional_variants, matrix.variant) }}" not in job(name).split("    steps:", 1)[0]:
        failures.append(f"{name} must let an optional variant's leg fail alone")
# Only a required leg may set the pending hand-off; an optional one never hands off.
if "notary_pending: ${{ !contains(needs.decide.outputs.optional_variants, matrix.variant) &&" not in TEXT:
    failures.append("notary_pending must come from a required leg only")
if "!contains(needs.decide.outputs.optional_variants, matrix.variant) && 'true' || 'false' }}" not in TEXT:
    failures.append("an optional leg must not hand a pending notarization to the arm64 recovery")

# publish: every feed loop takes the feeds this run actually publishes.
for name in ("Guard nightly-next publication", "Upload nightly-next appcasts to R2", "Upload nightly appcasts to R2"):
    body = step(name)
    if "appcast-x86_64.xml" in body or "$NIGHTLY_PUBLISH_FEEDS" not in body:
        failures.append(f"{name!r} must loop over $NIGHTLY_PUBLISH_FEEDS, not a fixed list")
publish = step("Publish nightly release assets")
if "$NIGHTLY_PUBLISH_VARIANTS" not in publish or "$NIGHTLY_PUBLISH_FEEDS" not in publish:
    failures.append("'Publish nightly release assets' must publish the chosen variants and feeds on nightly-next")
assemble = step("Assemble legacy nightly names")
if "$NIGHTLY_PUBLISH_VARIANTS" not in assemble:
    failures.append("'Assemble legacy nightly names' must check the chosen thin variants on nightly-next")
notes = step("Prepare nightly release notes and appcast summaries")
if "--feeds" not in notes or "$NIGHTLY_PUBLISH_FEEDS" not in notes or "Intel:" not in notes:
    failures.append("the release notes step must pass --feeds from $NIGHTLY_PUBLISH_FEEDS and list Intel")


def run_choose(variants, optional, source, files, build="123"):
    """Execute 'Choose the variants to publish' against a fixture publish dir."""
    body = step("Choose the variants to publish")
    script = textwrap.dedent(body.split("        run: |\n", 1)[1])
    with tempfile.TemporaryDirectory(prefix="nightly-choose-") as directory:
        root = Path(directory)
        for name, text in files.items():
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text(text)
        env = {"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
               "VARIANTS": json.dumps(variants), "OPTIONAL_VARIANTS": optional, "SOURCE": source,
               "NIGHTLY_FEEDS": "appcast-arm64.xml appcast-x86_64.xml", "NIGHTLY_BUILD": build,
               "CHANNEL_DMG_PREFIX": "p", "GITHUB_ENV": str(root / "env"), "GITHUB_OUTPUT": str(root / "out")}
        subprocess.run(["/bin/bash", "-c", script], cwd=root, env=env, capture_output=True, text=True, check=True)
        envs = dict(line.split("=", 1) for line in (root / "env").read_text().splitlines())
        left = sorted(str(path.relative_to(root)) for path in (root / "nightly-out").iterdir())
        return envs["NIGHTLY_PUBLISH_VARIANTS"], envs["NIGHTLY_PUBLISH_FEEDS"], left


both = {f"nightly-out/{name}": "x" for name in (
    "p-arm64-123.dmg", "p-arm64.dmg", "appcast-arm64.xml", "p-x86_64-123.dmg", "p-x86_64.dmg", "appcast-x86_64.xml")}
passed = {**both, "tested/tested-x86_64.sha256": "d", "signed-verified/signed-verified-x86_64": "123\n"}
cases = {
    "x86_64 passed every leg": (passed, "own", ("arm64 x86_64", "appcast-arm64.xml appcast-x86_64.xml", 6)),
    "x86_64 final DMG not verified": ({k: v for k, v in passed.items() if not k.startswith("tested/")}, "own", ("arm64", "appcast-arm64.xml", 3)),
    "x86_64 signed app not verified": ({k: v for k, v in passed.items() if not k.startswith("signed-verified/")}, "own", ("arm64", "appcast-arm64.xml", 3)),
    "x86_64 record from another build": ({**passed, "signed-verified/signed-verified-x86_64": "122\n"}, "own", ("arm64", "appcast-arm64.xml", 3)),
    "recovered build": (passed, "recovered", ("arm64", "appcast-arm64.xml", 3)),
}
for label, (files, source, (want_variants, want_feeds, want_left)) in cases.items():
    got_variants, got_feeds, left = run_choose(["arm64", "x86_64"], "x86_64", source, files)
    if (got_variants, got_feeds, len(left)) != (want_variants, want_feeds, want_left) or (want_left == 3 and any("x86_64" in n for n in left)):
        failures.append(f"choose variants, {label}: got {got_variants!r} {got_feeds!r} {left}")
main_variants, _, _ = run_choose(["arm64", "x86_64", "universal"], "", "own", {"nightly-out/p-arm64.dmg": "x"})
if main_variants != "arm64 x86_64 universal":
    failures.append(f"choose variants on main must keep every variant, got {main_variants!r}")
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
    """Run the actual four build steps with recorder executables, never compilers."""
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
            "scripts/ci/run-xcodebuild-with-diagnostics.sh": 'shift; exec "$@"',
            "scripts/ci/run-with-helper-prebuild.py": 'while [ "${1:-}" != -- ]; do shift; done; shift; exec "$@"',
            "scripts/cmux-next/build-acpmux.sh": 'printf "%s" "$CMUX_NEXT_ACPMUX_ARCHS" > "$CAPTURE/acpmux"',
            "scripts/cmux-next/build-optchat-chief.sh": 'printf "%s" "$CMUX_NEXT_OPTCHAT_CHIEF_ARCHS" > "$CAPTURE/chief"',
            "scripts/build-ghostty-cli-helper.sh": 'printf "%s\\n" "$@" > "$CAPTURE/ghostty"',
        }
        for path, body in stubs.items():
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
            target.chmod(0o755)
        capture = root / "capture"
        capture.mkdir()
        steps = (
            ("build-nightly-ghostty-cli-helper", "Build Ghostty CLI helper"),
            ("build-nightly-app", "Build in-tree acpmux for the compilation cache"),
            ("build-nightly-app", "Build the OptChat Chief (cmux-next)"),
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
    for helper in ("acpmux", "chief"):
        if commands[helper].replace(",", " ").split() != expected.split():
            failures.append(f"{ref} fast={fast}: {helper} built {commands[helper]!r}, expected {expected!r}")
    helper_args = commands["ghostty"].splitlines()
    if ("--universal" in helper_args) == arm64_only:
        failures.append(f"{ref} fast={fast}: Ghostty CLI helper does not follow the publish architectures")


if failures:
    print("FAIL: nightly-next variants\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next variants")
