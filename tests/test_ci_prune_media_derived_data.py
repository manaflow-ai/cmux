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


def scenario_held_tag():
    """A tour of another tag holds its lock before it builds into its idle dirs: they stay. (lsof can take
    seconds, so the holder outlives the whole prune.)"""
    lock = os.path.join(ROOT, "scripts", "ci", "media_tag_lock.py")
    with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside, \
            tempfile.TemporaryDirectory() as locks:
        build_tree(root, outside)
        held = subprocess.run([sys.executable, lock, "hold", "--tag", "ci-media-pr-1", "--lock-dir", locks,
                               "--wait", "0", "--max-hold", "60"], capture_output=True, text=True)
        _check(held.returncode == 0, "a tour holds ci-media-pr-1")
        child = hold_open(os.path.join(root, "cmux-ci-media-pr-3-base"))
        try:
            result = subprocess.run([sys.executable, SCRIPT, "--root", root, "--keep-tag", "ci-media-pr-9-base",
                                     "--keep-tag", "ci-media-pr-9-head", "--keep-others", "0", "--lock-dir", locks],
                                    capture_output=True, text=True)
        finally:
            child.kill()
            child.wait()
        print(result.stdout + result.stderr)
        names = remaining(root)
        _check("cmux-ci-media-pr-1-base" in names, "keeps a held tag's base")
        _check("cmux-ci-media-pr-1-head" in names, "keeps a held tag's head")
        _check("cmux-ci-media-pr-2-base" not in names, "still removes an idle unheld tag")


def scenario_tag_held_while_removing():
    """The prune holds a dir's tag lock until its rmtree finishes. A tour that asks for the tag mid-delete
    (media_tag_lock.py hold --wait 0) is refused, so it never builds into a dir that is being removed."""
    import importlib.util
    import shutil

    lock = os.path.join(ROOT, "scripts", "ci", "media_tag_lock.py")
    spec = importlib.util.spec_from_file_location("prune_media_derived_data_under_test", SCRIPT)
    prune = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(prune)
    with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as outside, \
            tempfile.TemporaryDirectory() as locks:
        build_tree(root, outside)
        tours = {}
        real_rmtree = shutil.rmtree

        def rmtree_while_a_tour_asks(path, *args, **kwargs):
            name = os.path.basename(str(path))
            tag = name[len("cmux-"):].removesuffix("-base").removesuffix("-head")
            tour = subprocess.run([sys.executable, lock, "hold", "--tag", tag, "--lock-dir", locks,
                                   "--wait", "0", "--max-hold", "1"], capture_output=True, text=True)
            tours[name] = tour.returncode
            return real_rmtree(path, *args, **kwargs)

        prune.shutil.rmtree = rmtree_while_a_tour_asks
        child = hold_open(os.path.join(root, "cmux-ci-media-pr-3-base"))
        try:
            argv = sys.argv
            sys.argv = [SCRIPT, "--root", root, "--keep-tag", "ci-media-pr-9-base", "--keep-tag",
                        "ci-media-pr-9-head", "--keep-others", "0", "--lock-dir", locks]
            try:
                prune.main()
            finally:
                sys.argv = argv
        finally:
            prune.shutil.rmtree = real_rmtree
            child.kill()
            child.wait()
        _check(bool(tours), "the prune removed at least one dir")
        for name, code in sorted(tours.items()):
            _check(code != 0, f"a tour asking for {name}'s tag mid-delete is refused (exit {code})")


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
    build = names.index("Build base and head tagged apps")
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


def scenario_old_head_prunes_with_the_lock():
    """A pull request branched before the tag lock checks out a head whose prune ignores held tags. The hold
    step takes both scripts from the run's commit then, so the prune step keeps a tag another tour holds."""
    import shutil

    lock = os.path.join(ROOT, "scripts", "ci", "media_tag_lock.py")
    steps = workflow["jobs"]["tour"]["steps"] if (workflow := yaml.safe_load(open(WORKFLOW))) else []
    by_name = {step.get("name"): step for step in steps}
    hold_step, prune_step = by_name.get("Hold this tour's tag"), by_name.get(STEP_NAME)
    _check(hold_step is not None and prune_step is not None, "the tour holds its tag, then prunes")
    if hold_step is None or prune_step is None:
        return
    with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as outside, \
            tempfile.TemporaryDirectory() as head, tempfile.TemporaryDirectory() as temp:
        root = os.path.join(home, "Library", "Developer", "Xcode", "DerivedData")
        locks = os.path.join(home, "Library", "Caches", "cmux-ci-media", "locks")
        os.makedirs(root)
        build_tree(root, outside)
        # The old head: no lock script, and a prune that removes every other media dir.
        os.makedirs(os.path.join(head, "scripts", "ci"))
        with open(os.path.join(head, "scripts", "ci", "prune_media_derived_data.py"), "w") as handle:
            handle.write("import glob, os, shutil, sys\n"
                         "for path in glob.glob(os.path.expanduser('~/Library/Developer/Xcode/DerivedData/cmux-ci-media-*')):\n"
                         "    if os.path.isdir(path) and not os.path.islink(path) and not os.path.basename(path).startswith('cmux-ci-media-pr-9'):\n"
                         "        shutil.rmtree(path)\n")
        # git fetch is a no-op and git show reads this checkout: the run's commit is the one under test.
        bin_dir = os.path.join(temp, "bin")
        os.makedirs(bin_dir)
        with open(os.path.join(bin_dir, "git"), "w") as handle:
            handle.write(f"#!/bin/sh\n[ \"$1\" = show ] || exit 0\nexec cat \"{ROOT}/${{2#*:}}\"\n")
        os.chmod(os.path.join(bin_dir, "git"), 0o755)
        github_env = os.path.join(temp, "github_env")
        open(github_env, "w").close()
        env = dict(os.environ, HOME=home, TOUR_TAG="ci-media-pr-9", GITHUB_SHA="0" * 40, RUNNER_TEMP=temp,
                   GITHUB_ENV=github_env, PATH=bin_dir + os.pathsep + os.environ["PATH"])
        other = subprocess.run([sys.executable, lock, "hold", "--tag", "ci-media-pr-1", "--lock-dir", locks,
                                "--wait", "0", "--max-hold", "60"], capture_output=True, text=True)
        _check(other.returncode == 0, "another tour holds ci-media-pr-1")
        try:
            held = subprocess.run(["bash", "-c", hold_step["run"]], cwd=head, env=env, capture_output=True,
                                  text=True, timeout=120)
            print(held.stdout + held.stderr)
            _check(held.returncode == 0, "the hold step holds this tour's tag")
            for line in open(github_env).read().splitlines():
                key, _, value = line.partition("=")
                env[key] = value
            pruned = subprocess.run(["bash", "-c", prune_step["run"]], cwd=head, env=env, capture_output=True,
                                    text=True, timeout=120)
            print(pruned.stdout + pruned.stderr)
        finally:
            # This tour's holder has no Runner.Worker to outlive, so it would hold for hours.
            subprocess.run(["pkill", "-f", temp], check=False)
        names = remaining(root)
        _check("cmux-ci-media-pr-1-base" in names and "cmux-ci-media-pr-1-head" in names,
               "an old head's tour keeps the tag another tour holds")
        _check("cmux-ci-media-pr-2-base" not in names, "an old head's tour still prunes an idle unheld tag")
        shutil.rmtree(locks, ignore_errors=True)


def main():
    scenario_keep_four()
    scenario_keep_zero()
    scenario_held_tag()
    scenario_tag_held_while_removing()
    scenario_old_head_prunes_with_the_lock()
    scenario_workflow_step()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print("all media DerivedData cap checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
