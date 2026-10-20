#!/usr/bin/env python3
"""A warm tour DerivedData drops its prebuilt modules when a binary pin changes.

The cmux-next tour keeps one DerivedData per tag warm across a pull request's
tours. Xcode rebuilt nothing from a new GhosttyNextKit pin's ghostty.h, so
the explicit module precompiled from the old one failed every importing Swift
module: "ghostty.h has been modified since the module file ... was built"
(job 117892119256, the Mac's last build of the tag had pinned e6a27a1fb and
the new head pins ced99dcde).

The build step now runs scripts/ci/media_module_cache_stamp.py around each
reload.sh: `clear` removes the precompiled module dirs when the binary pins
differ from the stamp of the tag's last good build, and `record` stamps it.

Removing only the module dirs broke every warm tour it touched: Xcode's
build description (Build/Intermediates.noindex/XCBuildData) still listed the
removed .pcm files as built, so the next compile died within a minute on
"module file '.../ExplicitPrecompiledModules/Darwin-*.pcm' not found". All 14
such failures on 2026-10-19 (e.g. job 118285853270) came right after a clear
in that same dir, and since a failed build never recorded the stamp, each
retry cleared and failed again (7 in a row on cmux-ci-media-feat-cmux-next-base).
`clear` now removes the whole Build dir with the module caches (the package
checkouts in SourcePackages stay) and stamps the dir right away: what is left
was built from no other pin, whether the build then succeeds or not.

Each tour now builds in the slot it claims on the Mac (scripts/ci/
media_tag_lock.py claim, DerivedData/cmux-ci-media-slot<N>-{base,head}), reused
by whichever pull request tours next, so each slot dir has its own stamp and a
pin change clears each slot's modules on that slot's own next build.

This checks the script on a fake source tree and DerivedData, then runs the
workflow's build step with a stand-in reload.sh that fails like Xcode did
when a module precompiled from an older pin is still there, or when its build
description lists a module file that is gone.
"""

import os
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "ci", "media_module_cache_stamp.py")
BUILD_SCRIPT = os.path.join(ROOT, "scripts", "ci", "media_build_app.sh")
CACHE_SCRIPT = os.path.join(ROOT, "scripts", "ci", "media_app_cache.py")
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-next-media.yml")
STEP_NAMES = ("Build the base app", "Build the head app")
PIN_A = "a" * 64
PIN_B = "b" * 64
MODULES = "Build/Intermediates.noindex/SwiftExplicitPrecompiledModules"
BUILD_DB_DIR = "Build/Intermediates.noindex/XCBuildData"
CHECKOUTS = "SourcePackages/checkouts"
FAILURES = []

# Stands in for reload.sh: like Xcode, it fails when a module precompiled from
# another pin is still in the tag's DerivedData, and otherwise "builds" the
# module from this tree's pin and an app.
FAKE_RELOAD = r"""#!/usr/bin/env bash
set -euo pipefail
tag="$2"
derived="$HOME/Library/Developer/Xcode/DerivedData/cmux-$tag"
pin="$(grep -o -E '[0-9a-f]{64}' Packages/Kit/Package.swift)"
pcm="$derived/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules/GhosttyNextKit.pcm"
darwin="$derived/Build/Intermediates.noindex/ExplicitPrecompiledModules/Darwin-B8F87C0RKU9WKGDHPXYECQVCK.pcm"
db="$derived/Build/Intermediates.noindex/XCBuildData/build.db"
if [ -f "$pcm" ] && [ "$(cat "$pcm")" != "$pin" ]; then
  echo "error: file 'include/ghostty.h' has been modified since the module file '$pcm' was built"
  exit 1
fi
# A warm build description trusts the modules it built and does not rebuild one that is gone.
if [ -f "$db" ]; then
  while read -r built; do
    [ -f "$built" ] || { echo "fatal error: module file '$built' not found"; exit 1; }
  done < "$db"
fi
mkdir -p "$(dirname "$pcm")" "$(dirname "$darwin")" "$(dirname "$db")" "$derived/Build/Products/Debug/cmux DEV $tag.app" \
  "$derived/SourcePackages/checkouts/sparkle"
echo "$pin" > "$pcm"
echo "$pin" > "$darwin"
printf '%s\n%s\n' "$pcm" "$darwin" > "$db"
printf 'App path:\n  %s\n' "$derived/Build/Products/Debug/cmux DEV $tag.app"
"""


def _check(ok, message):
    print(("ok: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def git(cwd, *args):
    subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)


def set_pin(source, pin, comment=""):
    write(
        os.path.join(source, "Packages", "Kit", "Package.swift"),
        f'// {comment}\n.binaryTarget(name: "GhosttyNextKit", url: "https://x/{pin[:9]}.zip",\n'
        f'    checksum: "{pin}")\n',
    )


def make_source(path, pin):
    os.makedirs(path)
    git(path, "init", "-q")
    set_pin(path, pin)
    write(os.path.join(path, "Packages", "App", "Package.resolved"), '{"pins": ["sparkle 2.6"]}\n')
    git(path, "add", "-A")


def make_derived(path):
    for relative in (MODULES, "ModuleCache.noindex", "Build/Products/Debug/app.app", BUILD_DB_DIR, CHECKOUTS):
        os.makedirs(os.path.join(path, relative))
        write(os.path.join(path, relative, "file"), "x")


def run(mode, source, derived):
    return subprocess.run(
        [sys.executable, SCRIPT, mode, "--source", source, "--derived-data", derived],
        capture_output=True,
        text=True,
    )


def modules_present(derived):
    return os.path.isdir(os.path.join(derived, MODULES)) and os.path.isdir(
        os.path.join(derived, "ModuleCache.noindex")
    )


def scenario_script():
    with tempfile.TemporaryDirectory() as tmp:
        source = os.path.join(tmp, "src")
        derived = os.path.join(tmp, "dd")
        make_source(source, PIN_A)

        result = run("clear", source, derived)
        _check(result.returncode == 0 and not os.path.exists(derived),
               "a tag with no DerivedData yet has nothing to clear")

        make_derived(derived)
        run("clear", source, derived)
        _check(not modules_present(derived), "a warm dir with no stamp drops its precompiled modules")
        _check(not os.path.exists(os.path.join(derived, BUILD_DB_DIR)),
               "it drops the build description that still lists them")
        _check(os.path.isdir(os.path.join(derived, CHECKOUTS)), "the package checkouts stay")
        make_derived_modules_again(derived)
        run("clear", source, derived)
        _check(modules_present(derived), "a cleared dir is stamped: the next tour does not clear it again")

        make_derived_modules_again(derived)
        run("record", source, derived)
        run("clear", source, derived)
        _check(modules_present(derived), "unchanged pins keep the precompiled modules")

        set_pin(source, PIN_A, comment="a comment, no pin change")
        run("clear", source, derived)
        _check(modules_present(derived), "a Package.swift edit that keeps the checksums clears nothing")

        set_pin(source, PIN_B)
        result = run("clear", source, derived)
        print(result.stdout + result.stderr)
        _check(not modules_present(derived), "a new binary target checksum drops the precompiled modules")

        make_derived_modules_again(derived)
        run("record", source, derived)
        write(os.path.join(source, "Packages", "App", "Package.resolved"), '{"pins": ["sparkle 2.7"]}\n')
        run("clear", source, derived)
        _check(not modules_present(derived), "a Package.resolved change drops the precompiled modules")


def make_derived_modules_again(derived):
    for relative in (MODULES, "ModuleCache.noindex"):
        os.makedirs(os.path.join(derived, relative), exist_ok=True)


def build_steps():
    with open(WORKFLOW) as handle:
        workflow = yaml.safe_load(handle)
    by_name = {step.get("name"): step for step in workflow["jobs"]["tour"]["steps"]}
    steps = [by_name.get(name) for name in STEP_NAMES]
    return None if None in steps else steps


def fake_checkout(path, pin):
    make_source(path, pin)
    write(os.path.join(path, "scripts", "reload.sh"), FAKE_RELOAD)
    os.chmod(os.path.join(path, "scripts", "reload.sh"), 0o755)
    os.makedirs(os.path.join(path, "scripts", "ci"))
    for script in (SCRIPT, BUILD_SCRIPT, CACHE_SCRIPT):
        shutil.copy(script, os.path.join(path, "scripts", "ci"))


def scenario_workflow_step():
    steps = build_steps()
    _check(steps is not None, f"the tour job has {STEP_NAMES} steps")
    if steps is None:
        return
    with tempfile.TemporaryDirectory() as tmp:
        home = os.path.join(tmp, "home")
        workspace = os.path.join(tmp, "workspace")
        runner_temp = os.path.join(tmp, "runner")
        os.makedirs(home)
        os.makedirs(runner_temp)
        fake_checkout(workspace, PIN_A)
        fake_checkout(os.path.join(runner_temp, "cmux-next-base"), PIN_A)
        env = dict(
            os.environ,
            HOME=home,
            GITHUB_WORKSPACE=workspace,
            RUNNER_TEMP=runner_temp,
            GITHUB_OUTPUT=os.path.join(tmp, "output"),
            RUNNER_NAME="runner-1",
            MEDIA_TOUR_CI=os.path.join(workspace, "scripts", "ci"),
            MEDIA_APP_RECIPE="0123456789ab",
            MERGE_BASE="0" * 40,
            BASE_APP="",
        )

        def tour(slot=0):
            for step in steps:
                result = subprocess.run(["bash", "-c", step["run"]], cwd=workspace, env=dict(env, TOUR_TAG=f"ci-media-slot{slot}"),
                                        capture_output=True, text=True)
                print(result.stdout + result.stderr)
                if result.returncode != 0:
                    break
            return result

        def head_pin(slot=0):
            pcm = os.path.join(home, f"Library/Developer/Xcode/DerivedData/cmux-ci-media-slot{slot}-head",
                               MODULES, "GhosttyNextKit.pcm")
            if not os.path.isfile(pcm):
                return None
            with open(pcm) as handle:
                return handle.read().strip()

        _check(tour().returncode == 0, "a cold tour builds base and head")
        _check(tour().returncode == 0, "a warm tour with the same pins builds")
        # The next pull request toured in this slot moves the GhosttyNextKit pin.
        set_pin(workspace, PIN_B)
        _check(tour().returncode == 0, "a warm tour after a GhosttyNextKit pin change builds")
        _check(tour().returncode == 0, "the next tour at the new pin builds warm")
        built = head_pin()
        _check(built == PIN_B, f"the head's module is rebuilt from the new pin (found {built and built[:9]})")

        # A concurrent tour builds slot 1 at the old pin; the next pin change
        # reaches slot 1 first, then slot 0.
        set_pin(workspace, PIN_A)
        _check(tour(1).returncode == 0, "a cold slot 1 builds base and head")
        _check(head_pin(1) == PIN_A and head_pin(0) == PIN_B, "slot 1 builds into its own DerivedData")
        set_pin(workspace, PIN_B)
        _check(tour(1).returncode == 0, "slot 1 rebuilds its modules after its own pin change")
        _check(head_pin(1) == PIN_B, "slot 1's module now has the new pin")
        set_pin(workspace, PIN_A)
        _check(tour(0).returncode == 0, "slot 0 clears its modules on its own pin change")
        _check(head_pin(0) == PIN_A and head_pin(1) == PIN_B, "clearing slot 0 leaves slot 1 warm")


def main():
    scenario_script()
    scenario_workflow_step()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print("all media module cache stamp checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
