#!/usr/bin/env python3
"""A run whose cmux-tui tree key has an active owner ends at once (cx-urd.26 cut b).

tree-owner-wait used to poll the owner every minute for up to 55 minutes on a
Linux runner: 21,801 job-minutes on 2026-10-12, and 221 of the 765 waits ended
by building the key anyway after a chain of failed owners. Now a waiter checks
once: a published tree or a live owner means no build here, an ended owner is
taken over by winning the key's claim, and a missing tree is repaired by the
next push of the key or cmux-tui-tree-request.yml (which re-runs a commit's run).

This runs the job's own script with fake curl, sleep and claim script, and
checks that the run that publishes asks for the nightly-next promotion even
when it is not a feat-cmux-next push (the feat push that shares its key no
longer waits to ask).
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
KEY = "8729cadfd262d8c13cad8f8ad5d7d54ca4984e01"

FAKE_CURL = r"""#!/usr/bin/env python3
import json, os, sys
from datetime import datetime, timedelta, timezone
def started(minutes):
    # A run that started this many minutes ago (default: just now).
    when = datetime.now(timezone.utc) - timedelta(minutes=float(minutes or 0))
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")
args = sys.argv[1:]
url = next(a for a in args if a.startswith("http"))
out = args[args.index("-o") + 1] if "-o" in args else None
if "/actions/artifacts?name=cmux-tui-tree-feat-builder-" in url:
    if os.environ.get("FAKE_BUILDERS", "") == "fail":
        sys.exit(22)
    ids = [i for i in os.environ.get("FAKE_BUILDERS", "").split(",") if i]
    print(json.dumps({"artifacts": [{"expired": False, "workflow_run": {"id": int(i)}} for i in ids]}))
    sys.exit(0)
if "/actions/runs/" in url and "/jobs" in url:
    jobs = [{"name": "cmux-tui tree preflight", "status": "completed"}]
    if os.environ.get("FAKE_NOTIFY_STATUS"):
        jobs.append({"name": "report an unpublished cmux-tui tree to cmux-next", "status": os.environ["FAKE_NOTIFY_STATUS"]})
    jobs += json.loads(os.environ.get("FAKE_DAEMON_JOBS", "[]"))
    print(json.dumps({"total_count": len(jobs), "jobs": jobs}))
    sys.exit(0)
if "/actions/runs/" in url and os.environ.get("FAKE_OWNER_ENDS_AFTER"):
    count_file = os.environ["FAKE_LOG"] + ".owner-reads"
    reads = int(open(count_file).read()) + 1 if os.path.exists(count_file) else 1
    open(count_file, "w").write(str(reads))
    if reads > int(os.environ["FAKE_OWNER_ENDS_AFTER"]):
        os.environ["FAKE_OWNER_STATUS"] = "completed"
if "/actions/runs/" in url:
    run_id = url.rsplit("/", 1)[1]
    if run_id in os.environ.get("FAKE_BUILDERS", "").split(","):
        print(json.dumps({"status": os.environ.get("FAKE_BUILDER_STATUS", "in_progress"),
                          "event": os.environ.get("FAKE_BUILDER_EVENT", "push"),
                          "head_branch": os.environ.get("FAKE_BUILDER_BRANCH", "feat-cmux-next"),
                          "run_started_at": started(os.environ.get("FAKE_BUILDER_MINUTES"))}))
        sys.exit(0)
    if os.environ["FAKE_OWNER_STATUS"] == "fail":
        sys.exit(22)
    print(json.dumps({"status": os.environ["FAKE_OWNER_STATUS"], "conclusion": os.environ.get("FAKE_OWNER_CONCLUSION", ""),
                      "event": os.environ.get("FAKE_OWNER_EVENT", "push"), "head_branch": os.environ.get("FAKE_OWNER_BRANCH", "feat-cmux-next"),
                      "head_sha": os.environ.get("FAKE_OWNER_SHA", "b" * 40),
                      "run_started_at": started(os.environ.get("FAKE_OWNER_MINUTES"))}))
    sys.exit(0)
if os.environ.get("FAKE_TREE_PUBLISHED") != "1":
    sys.exit(22)
if "daemon-tests.json" in url and os.environ.get("FAKE_MARKER", "1") != "1":
    sys.exit(22)
if "source.json" in url:
    print(json.dumps({"ref": os.environ.get("FAKE_SOURCE_REF", "refs/heads/op-lane"), "daemonTests": "separate"}))
    sys.exit(0)
key = url.split("/tree/")[1].split("/")[0]
names = ["cmux-tui-aarch64-apple-darwin", "cmux-tui-app-host-aarch64-apple-darwin", "cmux-tui-cloud-server-aarch64-apple-darwin"]
if "completion.json" in url:
    open(out, "w").write(json.dumps({"key": key, "binaries": {n: "a" * 64 for n in names}}))
elif ".sha256" in url:
    print("a" * 64 + "  x")
"""

FAKE_SLEEP = """#!/bin/sh
echo "sleep $*" >> "$FAKE_LOG"
"""

FAKE_CLAIM = """#!/bin/sh
echo "claim $*" >> "$FAKE_LOG"
[ -z "$FAKE_CLAIM_EXIT" ] || exit "$FAKE_CLAIM_EXIT"
echo "$FAKE_CLAIM_RESULT"
"""


def _check(cond, msg):
    (FAILURES.append(msg), print(f"FAIL: {msg}")) if not cond else print(f"ok: {msg}")


def job(name):
    return yaml.safe_load(open(WORKFLOW, encoding="utf-8"))["jobs"][name]


def wait_script():
    steps = job("tree-owner-wait")["steps"]
    return next(s["run"] for s in steps if s.get("id") == "wait")


def recheck_step():
    steps = job("tree-owner-wait")["steps"]
    return next((s for s in steps if s.get("id") == "recheck"), None)


def handoff_script():
    steps = job("notify-unpublished-tree")["steps"]
    return next(s for s in steps if "deferred" in s.get("name", ""))["run"]


def run_wait(owner, script=None, **fake):
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = os.path.join(tmp, "bin")
        os.makedirs(os.path.join(tmp, "scripts", "ci"))
        os.makedirs(bin_dir)
        for path, body in ((os.path.join(bin_dir, "curl"), FAKE_CURL), (os.path.join(bin_dir, "sleep"), FAKE_SLEEP),
                           (os.path.join(tmp, "scripts", "ci", "cmux-tui-tree-claim.sh"), FAKE_CLAIM),
                           (os.path.join(tmp, "scripts", "ci", "cmux_tui_publisher_testing.py"),
                            open(os.path.join(ROOT, "scripts", "ci", "cmux_tui_publisher_testing.py")).read())):
            with open(path, "w") as handle:
                handle.write(body)
            os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        output = os.path.join(tmp, "out")
        log = os.path.join(tmp, "log")
        open(output, "w").close()
        open(log, "w").close()
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", KEY=KEY, OWNER_RUN_ID=owner,
                   API_URL="https://api.github.invalid", REPOSITORY="manaflow-ai/cmux", GH_TOKEN="x",
                   SERVER_URL="https://github.invalid", GITHUB_OUTPUT=output, GITHUB_RUN_ID="5", RUNNER_TEMP=tmp,
                   FAKE_LOG=log)
        env = {**env, "EVENT_NAME": "push", "REF": "refs/heads/feat-cmux-next", "SHA": "f" * 40,
               "FAKE_OWNER_STATUS": "in_progress", "FAKE_CLAIM_RESULT": "owner=7 granted=false",
               "DAEMON_POOL": "glaeda-side-light-xcode-26.6", **fake}
        env["TREE_READY"] = "true" if env.get("FAKE_TREE_PUBLISHED") == "1" else "false"
        env["DAEMON_TESTED"] = "false" if env["TREE_READY"] == "true" and env.get("FAKE_MARKER", "1") != "1" else "true"
        result = subprocess.run(["bash", "-e", "-c", script or wait_script()], cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
        return result, open(output).read(), open(log).read()


def check_recheck():
    """A waiter that deferred looks at its owner once more after leaving its marker.

    2026-10-14: an owner's hand-off (notify-unpublished-tree) re-runs only the
    runs whose cmux-tui-tree-deferred-<key> marker exists when it looks. A
    waiter that saw its owner live, then left its marker after that hand-off
    had looked (a cancelled owner ends within a minute), ended green with the
    key unpublished, and no later run of that commit built it. The feat-cmux-next
    tip is the run most likely to defer to an owner that is being cancelled.
    """
    step = recheck_step()
    _check(step is not None, "tree-owner-wait re-checks its owner after a deferral (step id recheck)")
    if step is None:
        return
    steps = job("tree-owner-wait")["steps"]
    marker = next(i for i, s in enumerate(steps) if "cmux-tui-tree-deferred-" in str(s.get("with", {}).get("name", "")))
    _check(steps.index(step) > marker and "steps.wait.outputs.deferred == 'true'" in str(step.get("if", "")),
           "the re-check runs after the deferred marker is uploaded, and only for a deferring run")
    takeover = str(job("tree-owner-wait")["outputs"]["takeover"])
    _check("steps.recheck.outputs.takeover == 'true'" in takeover and "steps.wait.outputs.takeover" in takeover,
           f"the job's takeover output follows a re-check takeover ({takeover})")
    _check("steps.wait.outputs.owner" in str(step.get("env", {}).get("OWNER_RUN_ID", "")),
           "the re-check looks at the run the wait step deferred to")
    result, out, log = run_wait("4", FAKE_OWNER_BRANCH="op-next-idle-caret", FAKE_BUILDERS="9")
    _check("owner=9" in out, f"the wait step names the run it deferred to ({out.strip()!r})")

    script = step["run"]
    result, out, log = run_wait("4", script=script, FAKE_OWNER_STATUS="completed", FAKE_OWNER_CONCLUSION="cancelled",
                                FAKE_CLAIM_RESULT="owner=5 granted=true")
    _check(result.returncode == 0 and "takeover=true" in out,
           f"an owner cancelled after the first look, tree unpublished: the waiter wins the claim and builds ({out.strip()!r}, {result.stderr.strip()[-300:]!r})")
    result, out, log = run_wait("4", script=script, FAKE_OWNER_STATUS="completed", FAKE_OWNER_CONCLUSION="failure",
                                FAKE_CLAIM_RESULT="owner=4 granted=false")
    _check(result.returncode == 0 and "takeover=true" in out and log.count("claim ") == 2,
           f"a claim that still names the ended owner is asked again, then the waiter builds ({out.strip()!r}, {log.strip()!r})")
    result, out, log = run_wait("4", script=script, FAKE_OWNER_STATUS="completed", FAKE_OWNER_CONCLUSION="cancelled",
                                FAKE_CLAIM_EXIT="3")
    _check(result.returncode == 0 and "takeover=true" in out,
           f"an ended owner and no claim authority: the waiter builds ({out.strip()!r})")
    result, out, log = run_wait("4", script=script, FAKE_OWNER_STATUS="completed", FAKE_OWNER_CONCLUSION="cancelled",
                                FAKE_CLAIM_RESULT="owner=7 granted=false")
    _check(result.returncode == 0 and "takeover=false" in out,
           f"another run already took the key over (the hand-off re-ran it): no second build ({out.strip()!r})")
    result, out, log = run_wait("4", script=script, FAKE_OWNER_STATUS="completed", FAKE_OWNER_CONCLUSION="success",
                                FAKE_TREE_PUBLISHED="1", FAKE_CLAIM_RESULT="owner=5 granted=true")
    _check(result.returncode == 0 and "takeover=false" in out and "claim" not in log,
           f"an owner that published: no build ({out.strip()!r})")
    result, out, log = run_wait("4", script=script)
    _check(result.returncode == 0 and "takeover=false" in out and "sleep" not in log and "claim" not in log,
           f"a live owner that has not started its hand-off: the marker stands, no waiting ({out.strip()!r}, {log.strip()!r})")
    result, out, log = run_wait("4", script=script, FAKE_NOTIFY_STATUS="queued")
    _check(result.returncode == 0 and "takeover=false" in out and "sleep" not in log,
           f"an owner whose hand-off has not started will see the marker: no waiting ({out.strip()!r})")
    result, out, log = run_wait("4", script=script, FAKE_NOTIFY_STATUS="in_progress", FAKE_OWNER_ENDS_AFTER="2",
                                FAKE_OWNER_CONCLUSION="cancelled", FAKE_CLAIM_RESULT="owner=5 granted=true")
    _check(result.returncode == 0 and "takeover=true" in out and "sleep" in log,
           f"an owner already handing off (it may have missed the marker): wait for it to end, then build ({out.strip()!r}, {log.strip()!r})")
    result, out, log = run_wait("4", script=script, FAKE_NOTIFY_STATUS="in_progress")
    _check(result.returncode == 0 and "takeover=false" in out and 0 < log.count("sleep") <= 16,
           f"an owner whose hand-off never ends: the wait is bounded ({out.strip()!r}, {log.count('sleep')} sleeps)")


def check_lease():
    """A live owner holds its key for a bounded lease, not until its job timeout.

    2026-10-28: owner run 40641041752 of tree 04cb6703 hung in a Zig package
    fetch for over 25 minutes (as 40630560459 had for 58). Every later
    feat-cmux-next push of the key saw a live owner and deferred, so nothing
    built the key until the owner timed out: the feat-cmux-next tree went two
    hours and 97 commits unpublished.
    """
    env = job("tree-owner-wait")["steps"]
    lease = next(s for s in env if s.get("id") == "wait")["env"].get("OWNER_LEASE_MINUTES")
    _check(lease is not None and 15 <= int(lease) <= 30,
           f"a live owner's lease is bounded so the newest tree publishes within about 30 minutes ({lease})")
    for status in ("in_progress", "queued"):
        result, out, log = run_wait("4", FAKE_OWNER_STATUS=status, FAKE_OWNER_MINUTES="40")
        _check(result.returncode == 0 and "takeover=true" in out and "feat_builder=true" in out and "deferred=false" in out,
               f"a feat-cmux-next push takes over a key whose {status} feat-cmux-next owner is past its lease ({out.strip()!r}, {result.stderr.strip()[-300:]!r})")
    result, out, log = run_wait("4", FAKE_OWNER_MINUTES="10")
    _check(result.returncode == 0 and "takeover=false" in out and "deferred=true" in out,
           f"a feat-cmux-next owner inside its lease still holds the key ({out.strip()!r})")
    result, out, log = run_wait("4", FAKE_OWNER_MINUTES="40", REF="refs/heads/op-next-other")
    _check(result.returncode == 0 and "takeover=false" in out,
           f"only a feat-cmux-next push takes a stuck owner's key over ({out.strip()!r})")
    result, out, log = run_wait("4", FAKE_OWNER_MINUTES="40", FAKE_TREE_PUBLISHED="1")
    _check(result.returncode == 0 and "takeover=false" in out,
           f"a stuck owner that published anyway: no build ({out.strip()!r})")
    # Later pushes defer to the run that took over, while it holds its own lease.
    result, out, log = run_wait("4", FAKE_OWNER_MINUTES="40", FAKE_BUILDERS="9", FAKE_BUILDER_MINUTES="5")
    _check(result.returncode == 0 and "takeover=false" in out and "owner=9" in out,
           f"a later push defers to the feat-cmux-next run that took a stuck owner's key over ({out.strip()!r})")
    result, out, log = run_wait("4", FAKE_OWNER_MINUTES="40", FAKE_BUILDERS="9", FAKE_BUILDER_MINUTES="40")
    _check(result.returncode == 0 and "takeover=true" in out,
           f"a feat-cmux-next builder past its own lease does not hold the key either ({out.strip()!r})")


def main():
    result, out, log = run_wait("4")
    _check(result.returncode == 0 and "takeover=false" in out and "sleep" not in log and "claim" not in log,
           f"a live owner and an unpublished tree: no build, no waiting and no claim ({result.returncode}, {out.strip()!r}, {log.strip()!r})")

    result, out, log = run_wait("4", FAKE_OWNER_STATUS="completed", FAKE_OWNER_CONCLUSION="failure",
                                FAKE_CLAIM_RESULT="owner=5 granted=true")
    _check(result.returncode == 0 and "takeover=true" in out and "sleep" not in log,
           f"an owner that ended without publishing is taken over by the claim winner ({out.strip()!r}, {log.strip()!r})")

    result, out, log = run_wait("4", FAKE_OWNER_STATUS="completed", FAKE_OWNER_CONCLUSION="failure",
                                FAKE_CLAIM_RESULT="owner=7 granted=false")
    _check(result.returncode == 0 and "takeover=false" in out and "sleep" not in log,
           f"a claim another live run holds: no build and no waiting ({out.strip()!r}, {log.strip()!r})")

    result, out, log = run_wait("4", FAKE_OWNER_STATUS="fail", FAKE_CLAIM_RESULT="owner=5 granted=true")
    _check(result.returncode == 0 and "takeover=true" in out,
           f"an unreadable owner status still lets the claim winner build ({out.strip()!r})")

    result, out, log = run_wait("4", FAKE_OWNER_STATUS="completed", FAKE_OWNER_CONCLUSION="failure",
                                FAKE_CLAIM_RESULT="owner=4 granted=false")
    _check(result.returncode == 0 and "takeover=true" in out and log.count("claim ") == 2,
           f"a claim that still names the ended owner is asked again, then does not strand the key ({out.strip()!r}, {log.strip()!r})")

    result, out, log = run_wait("4")
    _check("deferred=true" in out, f"a run that defers to a live owner says so ({out.strip()!r})")
    uploads = [s for s in job("tree-owner-wait")["steps"] if "upload-artifact" in str(s.get("uses", ""))]
    _check(any("cmux-tui-tree-deferred-" in str(s.get("with", {}).get("name", "")) and "deferred" in str(s.get("if", ""))
               for s in uploads), "a deferring run leaves a cmux-tui-tree-deferred-<key> marker")

    # hq-a3 2026-10-14: a feat-cmux-next push never waits for a branch run that
    # owns its key (that run publishes only after its macOS daemon tests).
    for status in ("in_progress", "queued"):
        result, out, log = run_wait("4", FAKE_OWNER_STATUS=status, FAKE_OWNER_BRANCH="op-next-idle-caret")
        _check(result.returncode == 0 and "takeover=true" in out and "deferred=false" in out and "claim" not in log,
               f"a feat-cmux-next push builds a key a {status} branch run owns ({out.strip()!r}, {log.strip()!r})")
    # The most common lane flow: safe-push fast-forwards the side-branch
    # commit, so the branch owner builds the same commit. The publish jobs
    # keep whichever write-once publication lands first (cx-a1q4d).
    result, out, log = run_wait("4", FAKE_OWNER_BRANCH="op-next-idle-caret", FAKE_OWNER_SHA="f" * 40)
    _check(result.returncode == 0 and "takeover=true" in out and "feat_builder=true" in out,
           f"a feat-cmux-next push builds the same commit a live branch run owns ({out.strip()!r})")
    result, out, log = run_wait("4", FAKE_OWNER_BRANCH="op-next-idle-caret")
    _check("feat_builder=true" in out, f"the run that takes over says it builds the key ({out.strip()!r})")
    builder_marks = [s for s in job("tree-owner-wait")["steps"] if "upload-artifact" in str(s.get("uses", ""))]
    _check(any("cmux-tui-tree-feat-builder-" in str(s.get("with", {}).get("name", "")) and "feat_builder" in str(s.get("if", ""))
               for s in builder_marks), "a feat-cmux-next builder leaves a cmux-tui-tree-feat-builder-<key> marker")
    result, out, log = run_wait("4", FAKE_OWNER_BRANCH="op-next-idle-caret", FAKE_BUILDERS="9")
    _check(result.returncode == 0 and "takeover=false" in out and "deferred=true" in out and "feat_builder=false" in out,
           f"a later feat-cmux-next push defers to the active feat-cmux-next builder ({out.strip()!r})")
    result, out, log = run_wait("4", FAKE_OWNER_BRANCH="op-next-idle-caret", FAKE_BUILDERS="9", FAKE_BUILDER_STATUS="completed")
    _check(result.returncode == 0 and "takeover=true" in out,
           f"a builder that ended does not hold the key ({out.strip()!r})")
    result, out, log = run_wait("4", FAKE_OWNER_BRANCH="op-next-idle-caret", FAKE_BUILDERS="fail")
    _check(result.returncode == 0 and "takeover=false" in out,
           f"an unreadable builder list keeps the old deferral ({out.strip()!r})")
    result, out, log = run_wait("4", FAKE_OWNER_BRANCH="op-next-idle-caret", REF="refs/heads/op-next-other")
    _check(result.returncode == 0 and "takeover=false" in out,
           f"a branch push still defers to a live branch owner ({out.strip()!r})")
    result, out, log = run_wait("4", FAKE_OWNER_BRANCH="op-next-idle-caret", FAKE_TREE_PUBLISHED="1")
    _check(result.returncode == 0 and "takeover=false" in out,
           f"a key a branch run already published is not built again ({out.strip()!r})")

    result, out, log = run_wait("4", FAKE_TREE_PUBLISHED="1")
    _check(result.returncode == 0 and "takeover=false" in out, f"a published tree: no build ({out.strip()!r})")

    result, out, log = run_wait("")
    _check(result.returncode == 0 and "takeover=true" in out, f"the owner itself builds ({out.strip()!r})")

    # Every publisher publishes before its daemon tests end (cx-y0nf2). A run
    # defers only to an active feat-cmux-next push, which tests the tree and
    # requests the promotion: re-testing would queue a second job on the
    # promote runner. Any other owner is re-tested even while active: a
    # lane-branch push never tests (and stays in progress for its macOS cross
    # jobs), and a pull request or dispatch run never requests the promotion.
    for status in ("in_progress", "queued"):
        result, out, log = run_wait("4", FAKE_TREE_PUBLISHED="1", FAKE_MARKER="0", FAKE_OWNER_STATUS=status,
                                    FAKE_OWNER_BRANCH="feat-cmux-next")
        _check(result.returncode == 0 and "takeover=false" in out and "unmarked=false" in out,
               f"an unmarked tree whose feat-cmux-next push owner is {status} is not re-tested ({out.strip()!r})")
    # 2026-10-21: the owner's daemon-test job sat queued on a label the pool
    # variable no longer names, and every later push deferred to it.
    result, out, log = run_wait("4", FAKE_TREE_PUBLISHED="1", FAKE_MARKER="0", FAKE_OWNER_STATUS="in_progress",
                                FAKE_OWNER_BRANCH="feat-cmux-next", DAEMON_POOL="glaeda-side-light-xcode-26.6",
                                FAKE_DAEMON_JOBS='[{"name": "cmux_next_ daemon tests (macOS)", "status": "queued", "conclusion": null, "created_at": "2026-10-21T05:43:00Z", "labels": ["glaeda-side-std-xcode-26.6"]}]')
    _check(result.returncode == 0 and "unmarked=true" in out,
           f"an unmarked tree whose feat-cmux-next owner's daemon tests are stuck is re-tested ({out.strip()!r})")
    for event, branch, why in (("push", "op-next-idle-caret", "lane-branch push"),
                               ("pull_request_target", "op-next-idle-caret", "pull request"),
                               ("workflow_dispatch", "feat-cmux-next", "feat-cmux-next dispatch")):
        result, out, log = run_wait("4", FAKE_TREE_PUBLISHED="1", FAKE_MARKER="0", FAKE_OWNER_STATUS="in_progress",
                                    FAKE_OWNER_EVENT=event, FAKE_OWNER_BRANCH=branch)
        _check(result.returncode == 0 and "takeover=false" in out and "unmarked=true" in out,
               f"an unmarked tree whose active owner is a {why} run is re-tested ({out.strip()!r})")
    # A branch owner that a feat-cmux-next builder replaced: the run deferred
    # to is that builder, so its state decides, not the branch owner's.
    result, out, log = run_wait("4", FAKE_TREE_PUBLISHED="1", FAKE_MARKER="0", FAKE_OWNER_STATUS="in_progress",
                                FAKE_OWNER_BRANCH="op-next-idle-caret", FAKE_BUILDERS="9", FAKE_BUILDER_STATUS="in_progress")
    _check(result.returncode == 0 and "owner=9" in out and "unmarked=false" in out,
           f"an unmarked tree an active feat-cmux-next builder publishes is not re-tested ({out.strip()!r})")
    # The builder artifact list is repo-wide: a run that left one but is not a
    # feat-cmux-next push (another workflow, a pull request) does not hold the marker.
    for event, branch in (("pull_request", "op-next-idle-caret"), ("push", "op-next-idle-caret")):
        result, out, log = run_wait("4", FAKE_TREE_PUBLISHED="1", FAKE_MARKER="0", FAKE_OWNER_STATUS="in_progress",
                                    FAKE_OWNER_BRANCH="op-next-idle-caret", FAKE_BUILDERS="9",
                                    FAKE_BUILDER_STATUS="in_progress", FAKE_BUILDER_EVENT=event, FAKE_BUILDER_BRANCH=branch)
        _check(result.returncode == 0 and "unmarked=true" in out,
               f"an active {event} builder on {branch} does not stop the re-test ({out.strip()!r})")
    for branch in ("cmux-tui-pin-0123456789ab", "feat-cmux-next"):
        result, out, log = run_wait("4", FAKE_TREE_PUBLISHED="1", FAKE_MARKER="0", FAKE_OWNER_STATUS="completed",
                                    FAKE_OWNER_CONCLUSION="failure", FAKE_OWNER_BRANCH=branch)
        _check(result.returncode == 0 and "takeover=false" in out and "unmarked=true" in out,
               f"an unmarked tree whose {branch} owner ended is re-tested ({out.strip()!r})")
    result, out, log = run_wait("", FAKE_TREE_PUBLISHED="1", FAKE_MARKER="0")
    _check(result.returncode == 0 and "takeover=false" in out and "deferred=true" in out and "unmarked=true" in out,
           f"a published unmarked tree with no live owner leaves a takeover marker ({out.strip()!r})")
    result, out, log = run_wait("4", FAKE_TREE_PUBLISHED="1", FAKE_MARKER="0", FAKE_OWNER_STATUS="fail")
    _check(result.returncode == 0 and "unmarked=true" in out,
           f"an unmarked tree whose owner cannot be read is re-tested ({out.strip()!r})")
    result, out, log = run_wait("4", FAKE_TREE_PUBLISHED="1", FAKE_OWNER_STATUS="completed")
    _check(result.returncode == 0 and "unmarked=false" in out, f"a marked tree is not flagged ({out.strip()!r})")

    _check({"macos-cross-shadow", "macos-cross-runtime-x86_64"} <= set(job("notify-unpublished-tree")["needs"]),
           "the hand-off runs after the jobs that keep the owner in progress")
    _check(int(job("tree-owner-wait")["timeout-minutes"]) <= 10, "the owner check holds a runner for at most 10 minutes")

    promote = job("request-nightly-next")
    condition = promote["if"]
    _check("refs/heads/feat-cmux-next" in condition and "github.ref != 'refs/heads/feat-cmux-next' && needs.publish-tree-tested.result == 'success'" in condition,
           "a publishing run on another branch asks for the nightly-next promotion of the feat-cmux-next head that shares its key")
    checkout = next(s for s in promote["steps"] if "checkout" in str(s.get("uses", "")))
    _check("feat-cmux-next" in str(checkout["with"]["ref"]), "that request runs from the feat-cmux-next head's own checkout")

    # The hand-off's ordering, marker use, re-run cap and quota skip are tested in
    # tests/test_cmux_tui_tree_handoff.py, which runs the script with a fake gh.
    try:
        script = handoff_script()
    except (StopIteration, KeyError):
        _check(False, "notify-unpublished-tree hands the key to a run that deferred to it")
    else:
        _check("scripts/ci/cmux_tui_tree_handoff.py" in script,
               "notify-unpublished-tree hands the key on through scripts/ci/cmux_tui_tree_handoff.py")

    check_lease()
    check_recheck()

    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print("PASS: a waiter checks its key's owner once instead of holding a runner")
    return 0


if __name__ == "__main__":
    sys.exit(main())
