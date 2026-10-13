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
args = sys.argv[1:]
url = next(a for a in args if a.startswith("http"))
out = args[args.index("-o") + 1] if "-o" in args else None
if "/actions/runs/" in url:
    if os.environ["FAKE_OWNER_STATUS"] == "fail":
        sys.exit(22)
    print(json.dumps({"status": os.environ["FAKE_OWNER_STATUS"], "conclusion": os.environ.get("FAKE_OWNER_CONCLUSION", "")}))
    sys.exit(0)
if os.environ.get("FAKE_TREE_PUBLISHED") != "1":
    sys.exit(22)
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
echo "$FAKE_CLAIM_RESULT"
"""


def _check(cond, msg):
    (FAILURES.append(msg), print(f"FAIL: {msg}")) if not cond else print(f"ok: {msg}")


def job(name):
    return yaml.safe_load(open(WORKFLOW, encoding="utf-8"))["jobs"][name]


def wait_script():
    steps = job("tree-owner-wait")["steps"]
    return next(s["run"] for s in steps if s.get("id") == "wait")


FAKE_GH = """#!/bin/sh
echo "gh $*" >> "$FAKE_LOG"
case "$*" in
  *--jq*) printf '%b' "$FAKE_ARTIFACTS" ;;
  *"run rerun $FAKE_RERUN_FAILS"*) exit 1 ;;
esac
"""


def handoff_script():
    steps = job("notify-unpublished-tree")["steps"]
    return next(s for s in steps if "deferred" in s.get("name", ""))["run"]


def run_handoff(artifacts, rerun_fails="none"):
    with tempfile.TemporaryDirectory() as tmp:
        gh = os.path.join(tmp, "gh")
        with open(gh, "w") as handle:
            handle.write(FAKE_GH)
        os.chmod(gh, os.stat(gh).st_mode | stat.S_IXUSR)
        log = os.path.join(tmp, "log")
        open(log, "w").close()
        env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", KEY=KEY, RUN_ID="5",
                   GITHUB_REPOSITORY="manaflow-ai/cmux", GH_TOKEN="x", FAKE_LOG=log,
                   FAKE_ARTIFACTS=artifacts, FAKE_RERUN_FAILS=rerun_fails)
        result = subprocess.run(["bash", "-e", "-c", handoff_script()], cwd=tmp, env=env,
                                capture_output=True, text=True, timeout=60)
        return result, open(log).read()


def run_wait(owner, **fake):
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = os.path.join(tmp, "bin")
        os.makedirs(os.path.join(tmp, "scripts", "ci"))
        os.makedirs(bin_dir)
        for path, body in ((os.path.join(bin_dir, "curl"), FAKE_CURL), (os.path.join(bin_dir, "sleep"), FAKE_SLEEP),
                           (os.path.join(tmp, "scripts", "ci", "cmux-tui-tree-claim.sh"), FAKE_CLAIM)):
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
        env = {**env, "FAKE_OWNER_STATUS": "in_progress", "FAKE_CLAIM_RESULT": "owner=7 granted=false", **fake}
        result = subprocess.run(["bash", "-e", "-c", wait_script()], cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
        return result, open(output).read(), open(log).read()


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

    result, out, log = run_wait("4", FAKE_TREE_PUBLISHED="1")
    _check(result.returncode == 0 and "takeover=false" in out, f"a published tree: no build ({out.strip()!r})")

    result, out, log = run_wait("")
    _check(result.returncode == 0 and "takeover=true" in out, f"the owner itself builds ({out.strip()!r})")

    _check({"macos-cross-shadow", "macos-cross-runtime-x86_64"} <= set(job("notify-unpublished-tree")["needs"]),
           "the hand-off runs after the jobs that keep the owner in progress")
    _check(int(job("tree-owner-wait")["timeout-minutes"]) <= 10, "the owner check holds a runner for at most 10 minutes")

    promote = job("request-nightly-next")
    condition = promote["if"]
    _check("refs/heads/feat-cmux-next" in condition and "github.ref != 'refs/heads/feat-cmux-next' && needs.publish-tree.result == 'success'" in condition,
           "a publishing run on another branch asks for the nightly-next promotion of the feat-cmux-next head that shares its key")
    checkout = next(s for s in promote["steps"] if "checkout" in str(s.get("uses", "")))
    _check("feat-cmux-next" in str(checkout["with"]["ref"]), "that request runs from the feat-cmux-next head's own checkout")

    try:
        handoff_script()
    except (StopIteration, KeyError):
        _check(False, "notify-unpublished-tree hands the key to a run that deferred to it")
    else:
        result, log = run_handoff("11\\t9\\tlane\\n12\\t8\\tfeat-cmux-next\\n13\\t5\\tfeat-cmux-next\\n")
        _check(result.returncode == 0 and "run rerun 8" in log and "artifacts/12" in log
               and "run rerun 9" not in log and "rerun 5" not in log,
               f"an owner that ends unpublished re-runs one deferred run, feat-cmux-next first, never itself ({log.strip()!r})")
        result, log = run_handoff("11\\t9\\tlane\\n12\\t8\\tfeat-cmux-next\\n", rerun_fails="8")
        _check(result.returncode == 0 and "run rerun 9" in log and "artifacts/11" in log and "artifacts/12" not in log,
               f"a deferred run that cannot be re-run keeps its marker and passes the key to the next ({log.strip()!r})")
        result, log = run_handoff("")
        _check(result.returncode == 0 and "rerun" not in log, "no deferred run: nothing is re-run")

    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print("PASS: a waiter checks its key's owner once instead of holding a runner")
    return 0


if __name__ == "__main__":
    sys.exit(main())
