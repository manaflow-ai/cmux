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

This checks the script on a fake source tree and DerivedData, then runs the
workflow's build step twice with a stand-in reload.sh that fails like Xcode
did when a module precompiled from an older pin is still there.
"""

import os
import shutil
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "ci", "media_module_cache_stamp.py")
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-next-media.yml")
STEP_NAME = "Build base and head tagged apps"
PIN_A = "a" * 64
PIN_B = "b" * 64
MODULES = "Build/Intermediates.noindex/SwiftExplicitPrecompiledModules"
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
if [ -f "$pcm" ] && [ "$(cat "$pcm")" != "$pin" ]; then
  echo "error: file 'include/ghostty.h' has been modified since the module file '$pcm' was built"
  exit 1
fi
mkdir -p "$(dirname "$pcm")" "$derived/Build/Products/Debug/cmux DEV $tag.app"
echo "$pin" > "$pcm"
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


BUILD_DESCRIPTION = "Build/Intermediates.noindex/XCBuildData"


def make_derived(path):
    for relative in (MODULES, "ModuleCache.noindex", BUILD_DESCRIPTION, "Build/Products/Debug/app.app"):
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
        _check(os.path.isdir(os.path.join(derived, "Build/Products/Debug/app.app")),
               "the rest of the DerivedData stays warm")

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
        # Xcode's build description still lists the dropped modules as built,
        # so the next build asked clang for a Darwin pcm that no longer existed
        # ("module file ... ExplicitPrecompiledModules/Darwin-*.pcm not found",
        # 14 of 22 failed tours on 10-19, e.g. job 118285853270).
        _check(not os.path.exists(os.path.join(derived, BUILD_DESCRIPTION)),
               "dropping the modules also drops the build description that lists them")

        make_derived_modules_again(derived)
        run("record", source, derived)
        write(os.path.join(source, "Packages", "App", "Package.resolved"), '{"pins": ["sparkle 2.7"]}\n')
        run("clear", source, derived)
        _check(not modules_present(derived), "a Package.resolved change drops the precompiled modules")


def make_derived_modules_again(derived):
    for relative in (MODULES, "ModuleCache.noindex"):
        os.makedirs(os.path.join(derived, relative), exist_ok=True)


def build_step():
    with open(WORKFLOW) as handle:
        workflow = yaml.safe_load(handle)
    for step in workflow["jobs"]["tour"]["steps"]:
        if step.get("name") == STEP_NAME:
            return step
    return None


def fake_checkout(path, pin):
    make_source(path, pin)
    write(os.path.join(path, "scripts", "reload.sh"), FAKE_RELOAD)
    os.chmod(os.path.join(path, "scripts", "reload.sh"), 0o755)
    os.makedirs(os.path.join(path, "scripts", "ci"))
    shutil.copy(SCRIPT, os.path.join(path, "scripts", "ci"))


def scenario_workflow_step():
    step = build_step()
    _check(step is not None, f"the tour job has a '{STEP_NAME}' step")
    if step is None:
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
            TOUR_TAG="ci-media-pr-9",
        )

        def tour():
            result = subprocess.run(["bash", "-c", step["run"]], cwd=workspace, env=env,
                                    capture_output=True, text=True)
            print(result.stdout + result.stderr)
            return result

        _check(tour().returncode == 0, "a cold tour builds base and head")
        _check(tour().returncode == 0, "a warm tour with the same pins builds")
        # The pull request's next head moves the GhosttyNextKit pin.
        set_pin(workspace, PIN_B)
        _check(tour().returncode == 0, "a warm tour after a GhosttyNextKit pin change builds")
        pcm = os.path.join(home, "Library/Developer/Xcode/DerivedData/cmux-ci-media-pr-9-head",
                           MODULES, "GhosttyNextKit.pcm")
        with open(pcm) as handle:
            _check(handle.read().strip() == PIN_B, "the head's module is rebuilt from the new pin")


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
