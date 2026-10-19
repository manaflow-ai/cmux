#!/usr/bin/env python3
"""The cmux-next tour keeps a bounded number of media DerivedData dirs per Mac.

Each tour builds into ~/Library/Developer/Xcode/DerivedData/cmux-ci-media-<tag>
(one base and one head per pull request, one pair for merges), about 9 GiB
each, and nothing removed them: on 2026-10-14 one mini held 8 of them and a
merge tour failed reload.sh's 40 GiB free-space floor (run 38614931315).

Before building, the tour now removes the least recently used media dirs other
than its own two, oldest first, until at most --keep-others remain. A dir that
a process has open, or that a build touched recently, is never removed, and
nothing outside cmux-ci-media-* is touched.

This builds a fake DerivedData tree, holds one dir open from a child process,
and runs both the script and the workflow step that calls it.
"""

import os
import subprocess
import sys
import tempfile
import time

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "ci", "prune_media_derived_data.py")
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-next-media.yml")
STEP_NAME = "Bound the tour DerivedData on this Mac"
HOUR = 3600
FAILURES = []


def _check(ok, message):
    print(("ok: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def make_dir(root, name, age_seconds, recent_log=False):
    """A DerivedData-shaped dir last built age_seconds ago."""
    path = os.path.join(root, name)
    logs = os.path.join(path, "Logs", "Build")
    products = os.path.join(path, "Build", "Products", "Debug")
    os.makedirs(logs)
    os.makedirs(products)
    with open(os.path.join(path, "info.plist"), "w") as handle:
        handle.write("<plist/>")
    with open(os.path.join(products, "app.bin"), "w") as handle:
        handle.write("x" * 1024)
    stamp = time.time() - age_seconds
    for current, dirs, files in os.walk(path, topdown=False):
        for entry in files + dirs:
            os.utime(os.path.join(current, entry), (stamp, stamp))
        os.utime(current, (stamp, stamp))
    if recent_log:
        # A build that is writing this dir right now: its log dir is fresh,
        # everything else is old.
        now = time.time() - 60
        os.utime(logs, (now, now))
    return path


def build_tree(root, outside):
    make_dir(root, "cmux-ci-media-pr-1-base", 30 * HOUR)
    make_dir(root, "cmux-ci-media-pr-1-head", 29 * HOUR)
    make_dir(root, "cmux-ci-media-pr-2-base", 6 * HOUR)
    make_dir(root, "cmux-ci-media-pr-2-head", 5 * HOUR)
    make_dir(root, "cmux-ci-media-pr-3-base", 48 * HOUR)  # held open below
    make_dir(root, "cmux-ci-media-pr-4-head", 72 * HOUR, recent_log=True)
    make_dir(root, "cmux-ci-media-pr-9-base", 90 * HOUR)  # this run's own
    make_dir(root, "cmux-ci-media-pr-9-head", 90 * HOUR)
    make_dir(root, "cmux-nxpipe", 400 * HOUR)  # a non-media tag
    make_dir(root, "cmux-ci-media", 400 * HOUR)  # no tag after the prefix
    make_dir(outside, "target", 400 * HOUR)
    os.symlink(os.path.join(outside, "target"), os.path.join(root, "cmux-ci-media-pr-5-base"))
    with open(os.path.join(root, "cmux-ci-media-pr-6-head"), "w") as handle:
        handle.write("not a dir")


def hold_open(path):
    """A child process with a file under path open until it is killed."""
    target = os.path.join(path, "Build", "Products", "Debug", "app.bin")
    child = subprocess.Popen(
        [sys.executable, "-c", "import sys,time; f=open(sys.argv[1]); print('open', flush=True); time.sleep(600)", target],
        stdout=subprocess.PIPE,
        text=True,
    )
    child.stdout.readline()
    return child


def remaining(root):
    return sorted(os.listdir(root))


def run_script(root, keep_others):
    return subprocess.run(
        [
            sys.executable, SCRIPT,
            "--root", root,
            "--keep-tag", "ci-media-pr-9-base",
            "--keep-tag", "ci-media-pr-9-head",
            "--keep-others", str(keep_others),
        ],
        capture_output=True,
        text=True,
    )


def expect_kept_everywhere(root, outside, names):
    for name in [
        "cmux-ci-media-pr-3-base",
        "cmux-ci-media-pr-4-head",
        "cmux-ci-media-pr-9-base",
        "cmux-ci-media-pr-9-head",
        "cmux-nxpipe",
        "cmux-ci-media",
        "cmux-ci-media-pr-5-base",
        "cmux-ci-media-pr-6-head",
    ]:
        _check(name in names, f"keeps {name}")
    _check(
        os.path.isfile(os.path.join(outside, "target", "Build", "Products", "Debug", "app.bin")),
        "never follows a symlinked media dir",
    )


def scenario_keep_four():
    with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside:
        build_tree(root, outside)
        child = hold_open(os.path.join(root, "cmux-ci-media-pr-3-base"))
        try:
            result = run_script(root, keep_others=4)
        finally:
            child.kill()
            child.wait()
        print(result.stdout + result.stderr)
        _check(result.returncode == 0, "--keep-others 4 exits 0")
        names = remaining(root)
        _check("cmux-ci-media-pr-1-base" not in names, "removes the oldest idle pair's base")
        _check("cmux-ci-media-pr-1-head" not in names, "removes the oldest idle pair's head")
        _check("cmux-ci-media-pr-2-base" in names, "keeps the newer idle pair's base under the cap")
        _check("cmux-ci-media-pr-2-head" in names, "keeps the newer idle pair's head under the cap")
        expect_kept_everywhere(root, outside, names)


def scenario_keep_zero():
    with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside:
        build_tree(root, outside)
        child = hold_open(os.path.join(root, "cmux-ci-media-pr-3-base"))
        try:
            result = run_script(root, keep_others=0)
        finally:
            child.kill()
            child.wait()
        print(result.stdout + result.stderr)
        _check(result.returncode == 0, "--keep-others 0 exits 0")
        names = remaining(root)
        for name in [
            "cmux-ci-media-pr-1-base",
            "cmux-ci-media-pr-1-head",
            "cmux-ci-media-pr-2-base",
            "cmux-ci-media-pr-2-head",
        ]:
            _check(name not in names, f"cap of 0 removes idle {name}")
        # pr-3 (open) and pr-4 (built a minute ago) stay even over the cap.
        expect_kept_everywhere(root, outside, names)


def workflow_step():
    with open(WORKFLOW) as handle:
        workflow = yaml.safe_load(handle)
    steps = workflow["jobs"]["tour"]["steps"]
    names = [step.get("name") for step in steps]
    if STEP_NAME not in names:
        return None, None, names
    return steps[names.index(STEP_NAME)], names.index(STEP_NAME), names


def scenario_workflow_step():
    step, index, names = workflow_step()
    _check(step is not None, f"the tour job has a '{STEP_NAME}' step")
    if step is None:
        return
    build = names.index("Build the base app")
    _check(index < build, "the cap runs before the tour builds")
    _check(step.get("continue-on-error") is True, "a failed cap never fails the tour")
    with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as outside:
        root = os.path.join(home, "Library", "Developer", "Xcode", "DerivedData")
        os.makedirs(root)
        build_tree(root, outside)
        env = dict(os.environ, HOME=home, TOUR_TAG="ci-media-pr-9")
        child = hold_open(os.path.join(root, "cmux-ci-media-pr-3-base"))
        try:
            result = subprocess.run(
                ["bash", "-c", step["run"]], cwd=ROOT, env=env, capture_output=True, text=True
            )
        finally:
            child.kill()
            child.wait()
        print(result.stdout + result.stderr)
        _check(result.returncode == 0, "the workflow step exits 0")
        names = remaining(root)
        _check("cmux-ci-media-pr-1-base" not in names, "the workflow step removes an idle old dir")
        expect_kept_everywhere(root, outside, names)


def main():
    scenario_keep_four()
    scenario_keep_zero()
    scenario_workflow_step()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print("all media DerivedData cap checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
