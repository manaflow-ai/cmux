#!/usr/bin/env python3
"""A lane-branch push publishes its cmux-tui tree without the daemon tests.

The cmux_next_ daemon tests ran on every branch push with a new tree key, on
the owned minis' shared side lane: 17 of the 48 daemon-test jobs queued there
at 2026-10-14 12:59Z were lane-branch pushes. A feat-cmux-next pull request's
own run (pull_request_target) and its cmux-tui-pin-* merge tree already test
the tree that gates the merge. So a lane-branch push now builds and publishes
its tree (source.json daemonTests "separate") with no daemon-tests marker, and
any run that does test (feat-cmux-next, cmux-tui-pin-*, next-batch/*, main,
a pull request, a dispatch, or a push whose head commit carries the trailer
`Cmux-Daemon-Tests: run`) runs them when it finds such a tree unmarked.

This runs the tree preflight's own policy step against real commits, and
checks the jobs that consume its output.
"""

import os
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-tui-artifacts.yml")
FAILURES = []


def _check(ok, message):
    if not ok:
        FAILURES.append(message)


def jobs():
    with open(WORKFLOW, encoding="utf-8") as handle:
        return yaml.safe_load(handle)["jobs"]


def policy_step():
    steps = jobs()["tree-preflight"]["steps"]
    found = [step for step in steps if step.get("id") == "daemon-policy"]
    if len(found) != 1:
        raise SystemExit("FAIL: tree-preflight has no daemon-policy step")
    return found[0]["run"]


def run_policy(event, ref, message):
    with tempfile.TemporaryDirectory() as tmp:
        git = ["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@example.com"]
        subprocess.run(["git", "init", "-q", tmp], check=True)
        subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", message], check=True)
        output = os.path.join(tmp, "github-output")
        open(output, "w").close()
        env = {"PATH": os.environ["PATH"], "HOME": tmp, "GITHUB_OUTPUT": output,
               "EVENT_NAME": event, "REF": ref}
        result = subprocess.run(["bash", "-c", policy_step()], cwd=tmp, env=env,
                                capture_output=True, text=True)
        if result.returncode != 0:
            return f"exit {result.returncode}: {result.stderr.strip()}"
        values = dict(line.split("=", 1) for line in open(output).read().splitlines() if "=" in line)
        return values.get("daemon_tests")


def main():
    plain = "lane: change a thing"
    opted = "lane: change a thing\n\nCmux-Daemon-Tests: run"
    cases = [
        ("push", "refs/heads/codex/some-lane", plain, "false", "a lane-branch push skips the daemon tests"),
        ("push", "refs/heads/codex/some-lane", opted, "true", "the Cmux-Daemon-Tests: run trailer opts a lane push in"),
        ("push", "refs/heads/codex/some-lane", "x\n\nCmux-Daemon-Tests: skip", "false", "only the value run opts in"),
        ("push", "refs/heads/feat-cmux-next", plain, "true", "feat-cmux-next pushes still run them"),
        ("push", "refs/heads/cmux-tui-pin-0123456789ab", plain, "true", "pin (merge tree) pushes still run them"),
        ("push", "refs/heads/next-batch/abc", plain, "true", "next-batch pushes still run them"),
        ("push", "refs/heads/main", plain, "true", "main pushes still run them"),
        ("pull_request_target", "refs/heads/feat-cmux-next", plain, "true", "pull requests still run them"),
        ("workflow_dispatch", "refs/heads/codex/some-lane", plain, "true", "a dispatch on a lane branch runs them"),
    ]
    for event, ref, message, want, why in cases:
        got = run_policy(event, ref, message)
        _check(got == want, f"{why}: {event} {ref} -> {got!r}, want {want!r}")

    all_jobs = jobs()
    preflight = all_jobs["tree-preflight"]
    _check(preflight["outputs"].get("daemon_tests") == "${{ steps.daemon-policy.outputs.daemon_tests }}",
           "tree-preflight exports daemon_tests")

    daemon_if = str(all_jobs["cmux-next-daemon-tests"]["if"])
    _check(daemon_if.count("needs.tree-preflight.outputs.daemon_tests == 'true'") >= 2,
           "both daemon-test paths (new tree, unmarked published tree) need daemon_tests")
    _check("needs.tree-preflight.outputs.tree_ready == 'true' && needs.tree-preflight.outputs.daemon_tested == 'false'"
           in daemon_if, "a testing run that finds a published tree with no marker tests it")
    _check("github.ref != 'refs/heads/main'" in daemon_if, "main keeps its own rule for published trees")

    _check("needs.tree-owner-wait.outputs.unmarked == 'true'" in daemon_if,
           "a run whose owner published the tree unmarked during its preflight tests it")
    _check(all_jobs["tree-owner-wait"]["outputs"].get("unmarked") == "${{ steps.wait.outputs.unmarked }}",
           "tree-owner-wait exports unmarked")

    publish = all_jobs["publish-tree"]
    _check("needs.tree-preflight.outputs.daemon_tests != 'true'" in str(publish["if"]),
           "a lane-branch push publishes its tree without the daemon tests")
    mark = next(step for step in publish["steps"] if step.get("name") == "Mark the tree daemon-tested before publishing it")
    _check(mark.get("if") == "${{ github.ref != 'refs/heads/feat-cmux-next' && needs.tree-preflight.outputs.daemon_tests == 'true' }}",
           f"an untested publish writes no daemon-tests marker ({mark.get('if')!r})")

    marker_if = str(all_jobs["publish-tree-tested"]["if"])
    _check("needs.tree-preflight.outputs.tree_ready == 'true'" in marker_if
           and "github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && needs.tree-preflight.outputs.tree_ready == 'true'" not in marker_if,
           "any run that tested an already published tree writes its marker")
    tested = all_jobs["publish-tree-tested"]
    _check("tree-owner-wait" in tested["needs"] and "needs.tree-owner-wait.outputs.unmarked == 'true'" in str(tested["if"]),
           "the run that tested an owner's unmarked tree writes its marker")

    if FAILURES:
        for failure in FAILURES:
            print(f"FAIL: {failure}")
        sys.exit(1)
    print("PASS: lane-branch pushes publish build-only; testing refs and opt-ins run the daemon tests")


if __name__ == "__main__":
    main()
