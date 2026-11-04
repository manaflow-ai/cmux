#!/usr/bin/env python3
"""tree-preflight's fallback owner election ends inside the job, with this run building.

When the tree-claim authority cannot be asked, the inspect step elects the
key's owner from the run list: it fetches each active feat-cmux-next run's
commit and computes its tree key. On 2026-10-28 the authority answered HTTP 000
and that loop fetched commit after commit until the 6 minute job timeout killed
it (run 40650195591, commit a09b77c1). GitHub reports that as cancelled and
nothing re-runs it, so the commit never built its tree and nightly-next could
not promote it.

This runs the inspect step on a scratch directory with a fake curl, git, claim
script and tree key script, and checks that a slow or hanging election stops at
its deadline (ELECTION_DEADLINE_SECONDS into the step), keeps the lowest owner
it found, and otherwise lets this run build.
"""

import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-tui-artifacts.yml")
FAILURES = []
KEY = "8729cadfd262d8c13cad8f8ad5d7d54ca4984e01"
LEGACY_KEY = "1111111111111111111111111111111111111111"
RUN_ID = "500"
SHA = "f" * 40

FAKE_CURL = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
url = next(a for a in args if a.startswith("http"))
if "/actions/workflows/cmux-tui-artifacts.yml/runs?branch=feat-cmux-next" in url:
    with open(os.environ["FAKE_LOG"], "a") as log:
        log.write("run list\n")
    runs = []
    for item in filter(None, os.environ.get("FAKE_RUNS", "").split(",")):
        run_id, sha = item.split(":")
        runs.append({"id": int(run_id), "head_sha": sha, "status": "in_progress"})
    print(json.dumps({"workflow_runs": runs}))
    sys.exit(0)
if "/actions/" in url:
    print(json.dumps({"workflow_runs": []}))
    sys.exit(0)
# No tree is published.
sys.exit(22)
"""

FAKE_GIT = r"""#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    ls-remote) printf '%s\t%s\n' "$SHA" "$REF"; exit 0 ;;
    fetch)
      echo "fetch ${!#}" >> "$FAKE_LOG"
      # A fetch that ignores SIGTERM ends only on SIGKILL.
      [[ -z "${FAKE_FETCH_IGNORES_TERM:-}" ]] || trap '' TERM
      exec sleep "${FAKE_FETCH_SECONDS:-0}" ;;
  esac
done
exit 0
"""

FAKE_TREE_KEY = r"""import os, sys, time
if sys.argv[3] != os.environ["SHA"]:
    time.sleep(float(os.environ.get("FAKE_KEY_SECONDS") or 0))
print(os.environ["FAKE_KEY"] if sys.argv[2] == "v2" else os.environ["FAKE_LEGACY_KEY"])
"""

FAKE_CLAIM = """#!/bin/sh
exit 3
"""


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def preflight_job():
    return yaml.safe_load(open(WORKFLOW, encoding="utf-8"))["jobs"]["tree-preflight"]


def inspect_step():
    return next(s for s in preflight_job()["steps"] if s.get("id") == "inspect")


def write(path, body, executable=True):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(body)
    if executable:
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)


def elect(runs, fetch_seconds, deadline, key_seconds=0, limit=40, **fake):
    """Runs the inspect step; returns (returncode or None on a hang, outputs, stdout, fetches, seconds)."""
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = os.path.join(tmp, "bin")
        write(os.path.join(bin_dir, "curl"), FAKE_CURL)
        write(os.path.join(bin_dir, "git"), FAKE_GIT)
        write(os.path.join(tmp, "scripts", "ci", "cmux-tui-tree-claim.sh"), FAKE_CLAIM)
        write(os.path.join(tmp, "scripts", "ci", "cmux_tui_tree_key.py"), FAKE_TREE_KEY, executable=False)
        output = os.path.join(tmp, "out")
        log = os.path.join(tmp, "log")
        open(output, "w").close()
        open(log, "w").close()
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", EVENT_NAME="push",
                   REF="refs/heads/feat-cmux-next", SHA=SHA, SOURCE_COMMIT=SHA, REPOSITORY="manaflow-ai/cmux",
                   SERVER_URL="https://github.invalid", API_URL="https://api.github.invalid", RUN_ID=RUN_ID,
                   GITHUB_RUN_ID=RUN_ID, GH_TOKEN="x", STALE="false", DAEMON_POOL="blacksmith-32vcpu-ubuntu-2404",
                   GITHUB_OUTPUT=output, RUNNER_TEMP=tmp, FAKE_LOG=log, FAKE_KEY=KEY, FAKE_LEGACY_KEY=LEGACY_KEY,
                   FAKE_RUNS=",".join(f"{run_id}:{sha}" for run_id, sha in runs),
                   FAKE_FETCH_SECONDS=str(fetch_seconds), FAKE_KEY_SECONDS=str(key_seconds), **fake)
        if deadline is not None:
            env["ELECTION_DEADLINE_SECONDS"] = str(deadline)
        start = time.monotonic()
        proc = subprocess.Popen(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", inspect_step()["run"]],
                                cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                start_new_session=True)
        try:
            stdout, _ = proc.communicate(timeout=limit)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            stdout, _ = proc.communicate()
            code = None
        seconds = time.monotonic() - start
        outputs = dict(line.split("=", 1) for line in open(output).read().splitlines() if "=" in line)
        logged = open(log).read().splitlines()
        fetches = [line for line in logged if line.startswith("fetch ")]
        if "run list" not in logged:
            fetches = None
        return code, outputs, stdout, fetches, seconds


def main():
    job = preflight_job()
    step = inspect_step()
    match = re.search(r'election_deadline="\$\{ELECTION_DEADLINE_SECONDS:-(\d+)\}"', step["run"])
    deadline = match and match.group(1)
    _check(deadline is not None,
           f"the inspect step sets the election's deadline (election_deadline={deadline!r})")
    if deadline is not None:
        # The steps before inspect (checkout, the read token's mint, bounded at
        # a minute, and the superseded check) and the same-SHA lookup after the
        # election (15 s) need the rest of the job time.
        _check(int(deadline) <= int(job["timeout-minutes"]) * 60 - 150,
               f"the election deadline ({deadline} s into the step) leaves 150 s of the job time for the rest")

    # Fast fetches: the lowest active run of the key owns it, as before.
    runs = [(480, "a" * 40), (420, "b" * 40), (450, "c" * 40)]
    code, out, stdout, fetches, _ = elect(runs, fetch_seconds=0, deadline=None)
    _check(code == 0 and out.get("owner_run_id") == "420" and "stopped at its deadline" not in stdout and len(fetches or []) == 3,
           f"a quick election elects the lowest active run of the key ({code}, {out.get('owner_run_id')!r}, {stdout[-400:]!r})")

    # Slow fetches: the election stops at its deadline and keeps the owner it found.
    runs = [(417 - i, f"{i:x}" * 40) for i in range(10)]
    code, out, stdout, fetches, seconds = elect(runs, fetch_seconds=1, deadline=3)
    _check(code == 0 and seconds < 5.5 and "::warning::the owner election stopped at its deadline, 3 s into this step" in stdout,
           f"a slow election stops at its deadline and says so ({code}, {seconds:.1f} s, {stdout[-400:]!r})")
    fetched = [str(run_id) for run_id, sha in runs if f"fetch {sha}" in (fetches or [])]
    _check(0 < len(fetches or []) < len(runs) and out.get("owner_run_id") in fetched
           and int(out.get("owner_run_id") or 0) <= int(fetched[0]),
           f"it keeps an owner among the runs it examined ({out.get('owner_run_id')!r}, fetched {fetched})")

    # A fetch or a key read that hangs ends at the deadline, and with no owner
    # found this run owns the key and builds (a duplicate build is fine).
    for name, slow in (("fetch", {"fetch_seconds": 600}), ("tree key read", {"fetch_seconds": 0, "key_seconds": 600}),
                       ("fetch that ignores SIGTERM", {"fetch_seconds": 600, "FAKE_FETCH_IGNORES_TERM": "1"})):
        code, out, stdout, fetches, seconds = elect([(410, "d" * 40), (405, "e" * 40)], deadline=3, **slow)
        _check(code == 0 and seconds < 7,
               f"a hanging {name} ends at the deadline instead of the job timeout ({code}, {seconds:.1f} s)")
        _check(code == 0 and out.get("owner_run_id") == "" and out.get("run_macos") == "true"
               and "::warning::the owner election stopped at its deadline" in stdout and "no owner found" in stdout,
               f"with no owner found by the deadline after a hanging {name}, this run builds the key ({out.get('owner_run_id')!r}, {out.get('run_macos')!r}, {stdout[-400:]!r})")

    # A step that reaches the election past its deadline asks for nothing.
    code, out, stdout, fetches, seconds = elect([(410, "d" * 40)], fetch_seconds=0, deadline=0)
    _check(code == 0 and fetches is None and out.get("owner_run_id") == "" and "after 0 candidate runs" in stdout,
           f"an election that starts past its deadline reads no run list, fetches nothing, and this run builds ({fetches}, {stdout[-300:]!r})")

    if FAILURES:
        print(f"{len(FAILURES)} failure(s)")
        return 1
    print("PASS: the fallback owner election ends at its deadline, with this run building")
    return 0


if __name__ == "__main__":
    sys.exit(main())
