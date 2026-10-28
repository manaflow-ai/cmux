#!/usr/bin/env python3
"""A lane-branch push publishes its cmux-tui tree without the daemon tests.

The cmux_next_ daemon tests ran on every branch push with a new tree key, on
the owned minis' shared side lane: 17 of the 48 daemon-test jobs queued there
at 2026-10-14 12:59Z were lane-branch pushes. A feat-cmux-next pull request's
cmux-tui-pin-* merge tree already tests the tree that gates the merge. So a lane-branch push now builds and publishes
its tree (source.json daemonTests "separate") with no daemon-tests marker, and
any run that does test (feat-cmux-next, cmux-tui-pin-*, next-batch/*, main,
a pull request, a dispatch, or a push whose head commit carries the trailer
`Cmux-Daemon-Tests: run`) runs them when it finds such a tree unmarked.

This runs the tree preflight's own policy step against real commits, and
checks the jobs that consume its output.
"""

import os
import stat
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


# files.cmux.com and the Actions API for tree-preflight's inspect step: a
# published tree whose source.json says daemonTests "separate" and names its
# publisher run (FAKE_SOURCE_RUN, status FAKE_SOURCE_STATUS or "fail").
FAKE_CURL = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
url = next(a for a in args if a.startswith("http")).split("?")[0]
log = os.environ["FAKE_LOG"]
open(log, "a").write(url + "\n")
out = args[args.index("-o") + 1] if "-o" in args else None
if "/actions/runs/" in url and url.endswith("/jobs"):
    print(json.dumps({"jobs": json.loads(os.environ.get("FAKE_DAEMON_JOBS", "[]"))}))
    sys.exit(0)
if "/actions/runs/" in url:
    if os.environ["FAKE_SOURCE_STATUS"] == "fail":
        sys.exit(22)
    print(json.dumps({"status": os.environ["FAKE_SOURCE_STATUS"], "event": os.environ["FAKE_SOURCE_EVENT"],
                      "head_branch": os.environ["FAKE_SOURCE_BRANCH"]}))
    sys.exit(0)
if "/actions/" in url:
    print("{}")
    sys.exit(0)
if "/tree/" not in url:
    sys.exit(0)
key = url.split("/tree/")[1].split("/")[0]
name = url.rsplit("/", 1)[1]
names = ["cmux-tui-aarch64-apple-darwin", "cmux-tui-app-host-aarch64-apple-darwin", "cmux-tui-cloud-server-aarch64-apple-darwin"]
if name == "daemon-tests.json" and os.environ.get("FAKE_MARKER") != "1":
    sys.exit(22)
if name == "completion.json":
    body = json.dumps({"key": key, "binaries": {n: "a" * 64 for n in names}})
elif name == "source.json":
    body = json.dumps({"key": key, "run": os.environ["FAKE_SOURCE_RUN"], "daemonTests": "separate"})
elif name.endswith(".sha256"):
    body = "a" * 64 + "  x\n"
else:
    body = ""
if out and out != "/dev/null":
    open(out, "w").write(body)
elif not out:
    sys.stdout.write(body)
"""


def run_preflight(source_status, source_run="77", marker="0", event="push", branch="feat-cmux-next", daemon_jobs="[]"):
    """tree-preflight's inspect step for a next-batch push whose tree is published."""
    steps = jobs()["tree-preflight"]["steps"]
    script = next(step["run"] for step in steps if step.get("id") == "inspect")
    sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = os.path.join(tmp, "bin")
        os.makedirs(bin_dir)
        curl = os.path.join(bin_dir, "curl")
        with open(curl, "w") as handle:
            handle.write(FAKE_CURL)
        os.chmod(curl, os.stat(curl).st_mode | stat.S_IXUSR)
        output, log = os.path.join(tmp, "out"), os.path.join(tmp, "log")
        open(output, "w").close()
        open(log, "w").close()
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", EVENT_NAME="push", REF="refs/heads/next-batch/abc",
                   SHA=sha, SOURCE_COMMIT=sha, HEAD_REPOSITORY="manaflow-ai/cmux", REPOSITORY="manaflow-ai/cmux",
                   SERVER_URL="https://github.invalid", API_URL="https://api.github.invalid", RUN_ID="5",
                   GITHUB_RUN_ID="5", GH_TOKEN="x", GITHUB_OUTPUT=output, RUNNER_TEMP=tmp, FAKE_LOG=log,
                   FAKE_SOURCE_STATUS=source_status, FAKE_SOURCE_RUN=source_run, FAKE_MARKER=marker,
                   FAKE_SOURCE_EVENT=event, FAKE_SOURCE_BRANCH=branch, FAKE_DAEMON_JOBS=daemon_jobs,
                   DAEMON_POOL="glaeda-side-light-xcode-26.6")
        result = subprocess.run(["bash", "-e", "-c", script], cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
        values = dict(line.split("=", 1) for line in open(output).read().splitlines() if "=" in line)
        return result, values, open(log).read()


def check_preflight_retest():
    """cx-y0nf2: an unmarked published tree waits only for an active feat-cmux-next push publisher.

    Every publisher publishes before its own daemon tests end. An active
    feat-cmux-next push tests the tree and requests the promotion itself, and
    re-testing in that window put a second job on the promote runner. Any other
    active publisher may never test it (a lane-branch push, in progress for its
    macOS cross jobs) or never request the promotion (a pull request or
    dispatch run), so the tree is tested now.
    """
    feat = ("push", "feat-cmux-next")
    cases = [
        ("in_progress", "77", "0", feat, "true", "an active feat-cmux-next push publisher's tree is not re-tested"),
        ("queued", "77", "0", feat, "true", "a queued feat-cmux-next push publisher's tree is not re-tested"),
        ("in_progress", "77", "0", ("push", "op-next-idle-caret"), "false", "an active lane-branch push publisher's tree is re-tested"),
        ("in_progress", "77", "0", ("pull_request_target", "op-next-idle-caret"), "false", "an active pull request publisher's tree is re-tested"),
        ("in_progress", "77", "0", ("workflow_dispatch", "feat-cmux-next"), "false", "an active dispatch publisher's tree is re-tested"),
        ("completed", "77", "0", feat, "false", "an ended publisher's unmarked tree is re-tested"),
        ("fail", "77", "0", feat, "false", "a publisher whose state cannot be read: re-tested"),
        ("in_progress", "5", "0", feat, "false", "this run's own unmarked tree (a re-run attempt) is re-tested"),
        ("in_progress", "77", "1", feat, "true", "a marked tree needs no test and no run lookup"),
    ]
    for status, run, marker, (event, branch), want, why in cases:
        result, values, log = run_preflight(status, run, marker, event, branch)
        got = values.get("daemon_tested")
        _check(result.returncode == 0 and values.get("tree_ready") == "true" and got == want,
               f"{why}: daemon_tested {got!r}, want {want!r} (exit {result.returncode}: {result.stderr.strip()[-300:]})")
        if marker == "1" or run == "5":
            _check("/actions/runs/" not in log, f"{why}: no run lookup")
    # 2026-10-21: the active publisher's daemon-test job sat queued on a label
    # the pool variable no longer names, and every later push deferred to it.
    result, values, log = run_preflight("in_progress", daemon_jobs='[{"name": "cmux_next_ daemon tests (macOS)", "status": "queued", "conclusion": null, "created_at": "2026-10-21T05:43:00Z", "labels": ["glaeda-side-std-xcode-26.6"]}]')
    _check(result.returncode == 0 and values.get("daemon_tested") == "false",
           f"a feat-cmux-next publisher whose daemon tests are stuck: re-tested ({values.get('daemon_tested')!r}, {result.stderr.strip()[-300:]})")


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
    _check("cmux-next-daemon-tests" not in publish["needs"] and "daemon_tests" not in str(publish["if"]),
           "a lane-branch push publishes its tree without the daemon tests, like every ref (cx-y0nf2)")
    _check("cmux-tui-mark-daemon-tested.sh" not in str(publish["steps"]),
           "a publish writes no daemon-tests marker; publish-tree-tested does, after the tests pass")

    marker_if = str(all_jobs["publish-tree-tested"]["if"])
    _check("needs.tree-preflight.outputs.tree_ready == 'true'" in marker_if
           and "github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && needs.tree-preflight.outputs.tree_ready == 'true'" not in marker_if,
           "any run that tested an already published tree writes its marker")
    check_preflight_retest()

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
